import Foundation

/// TikTok resolver.
///
/// TikTok's public web page embeds a `<script id="__UNIVERSAL_DATA_FOR_
/// REHYDRATION__">` blob that contains the full video metadata including
/// a `playAddr` URL. This is exactly what most public TikTok downloaders
/// scrape — the trick is sending cookies and a plausible desktop
/// User-Agent so the CDN doesn't reject the eventual download.
///
/// Strategy:
///  1. Resolve any short URL (`vm.tiktok.com/…`, `vt.tiktok.com/…`) by
///     letting URLSession follow redirects. `ephemeralSession` keeps a
///     cookie jar scoped to this resolve — important because TikTok
///     sets a cookie on first visit that the video CDN checks later.
///  2. Scrape the rehydration blob for the high-quality `playAddr`.
///     Fall back to the watermark-free `playAddr_h264` when present.
///  3. If the blob's gone, try `og:video` from the meta tags.
struct TikTokResolver: MediaResolver {
    let platform: SocialPlatform = .tiktok

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func resolve(_ url: URL) async throws -> ResolverResult {
        // A dedicated session so the cookie the TikTok landing page sets
        // (tt_chain_token, ttwid, …) is attached to the subsequent video
        // download. URLSession.shared would pool cookies across apps.
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        // Age/sensitivity-gated posts only expose playAddr to a logged-in
        // session. If the user saved a TikTok sessionid, seed the jar with it
        // so both the landing scrape and the CDN download go out authenticated.
        if let sid = KeychainStore.load(.tiktokSessionCookie),
           let cookie = HTTPCookie(properties: [
               .name: "sessionid", .value: sid, .domain: ".tiktok.com", .path: "/"
           ]) {
            config.httpCookieStorage?.setCookie(cookie)
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        // TikTok short URLs (vm.tiktok.com / vt.tiktok.com) redirect to
        // the canonical /@user/video/<id> URL. URLSession used to follow
        // those automatically, but newer iOS versions reject the redirect
        // with `URLError.badURL` when the Location header carries
        // unencoded characters — common because TikTok occasionally
        // appends UTM-style query params that include reserved chars.
        // We follow redirects manually with our own delegate so we can
        // sanitize the next URL before continuing.
        let landingURL: URL
        do {
            landingURL = try await Self.followRedirects(from: url, session: session)
        } catch let e as DownloadError { throw e }
        catch { throw DownloadError.networkFailed(error.localizedDescription) }

        var req = URLRequest(url: landingURL)
        req.timeoutInterval = 15
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let html: String
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                throw DownloadError.networkFailed("tiktok HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard let s = String(data: data, encoding: .utf8) else {
                throw DownloadError.resolutionFailed("non-UTF8 response.")
            }
            html = s
        } catch let e as DownloadError { throw e }
        catch { throw DownloadError.networkFailed(error.localizedDescription) }

        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        // The rehydration blob is the richest source. Try several field
        // names TikTok has used over time.
        // Cookies TikTok set while we fetched the landing page. The CDN
        // validates these on the video URL, so we re-attach them to the
        // download request via the resolver result's requestHeaders.
        let cookieHeader = Self.cookieHeader(from: session, for: url)
        let headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Referer": "https://www.tiktok.com/",
            "Range": "bytes=0-",
            "Cookie": cookieHeader
        ].filter { !$0.value.isEmpty }

        for key in ["playAddr_h264", "playAddr", "downloadAddr"] {
            if let candidate = Self.extractJSONString(html: html, key: key),
               let videoURL = URL(string: candidate) {
                return ResolverResult(
                    mediaURL: videoURL,
                    title: title,
                    thumbnailURL: thumb,
                    isVideo: true,
                    platform: .tiktok,
                    requestHeaders: headers
                )
            }
        }

        // Final fallback: og:video meta.
        if let videoString = HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(
                mediaURL: videoURL,
                title: title,
                thumbnailURL: thumb,
                isVideo: true,
                platform: .tiktok,
                requestHeaders: headers
            )
        }

        // No play URL and the page is an age/sensitivity gate → needs login.
        if html.contains("AgeGate") || html.contains("not be comfortable") {
            throw DownloadError.loginRequired(.tiktok)
        }
        throw DownloadError.resolutionFailed(
            "TikTok didn't expose playAddr/og:video — markup may have changed."
        )
    }

    /// Manually follow up to 5 redirects, sanitizing each Location URL
    /// so URLSession doesn't bail with `URLError.badURL` on a Location
    /// header that contains characters the strict URL parser rejects.
    private static func followRedirects(from url: URL,
                                        session: URLSession,
                                        maxHops: Int = 5) async throws -> URL {
        var current = sanitize(url)
        for _ in 0..<maxHops {
            var req = URLRequest(url: current)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 8
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            // Don't auto-follow — we want to inspect each redirect.
            let delegate = NoFollowDelegate()
            let (_, resp) = try await session.data(for: req, delegate: delegate)
            guard let http = resp as? HTTPURLResponse else { return current }
            if (300..<400).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                current = sanitize(next)
                continue
            }
            return current
        }
        return current
    }

    /// Rebuild a URL through `URLComponents` so the path and query are
    /// percent-encoded the way URLSession expects. Returns the input
    /// unchanged if components parsing fails for any reason.
    private static func sanitize(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        // URLComponents re-encodes path/query when we round-trip via .url.
        comps.percentEncodedQuery = comps.percentEncodedQuery
        return comps.url ?? url
    }

    /// Disables URLSession's automatic redirect handling. We need to see
    /// each Location header so we can sanitize it before continuing.
    private final class NoFollowDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // tell URLSession: don't follow
        }
    }

    /// Concatenate the cookie jar into a single `Cookie:` header value.
    /// Returns "" if no cookies match the URL — caller should drop the
    /// header entirely in that case.
    private static func cookieHeader(from session: URLSession, for url: URL) -> String {
        guard let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies(for: url), !cookies.isEmpty else { return "" }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Tiny targeted scan for `"key":"…"` in the rehydration blob.
    /// Full JSON parsing would be slow because TikTok's blob is huge.
    /// The captured value has JSON escapes (`\/`, `\u0026`) that we
    /// un-escape before handing off.
    private static func extractJSONString(html: String, key: String) -> String? {
        guard let raw = HTMLScraper.firstCaptureGroup(
            in: html,
            pattern: "\"\(key)\":\"([^\"]+)\""
        ) else { return nil }
        return Self.decodeJSONStringEscapes(raw)
    }

    /// Decode the subset of JSON string escapes that show up inside
    /// TikTok's inlined player JSON. Handles `\uXXXX` generically plus
    /// the bare `\/`, `\\`, `\"`, `\n`, `\t`, `\r` forms. We need the
    /// generic `\u` path so reserved URL chars (`?`, `=`, `&`) which
    /// TikTok serializes as `?`, `=`, `&` don't stay
    /// backslash-escaped and trip URLSession's `URLError.badURL`.
    private static func decodeJSONStringEscapes(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { out.append(c); break }
                switch s[next] {
                case "/":  out.append("/");  i = s.index(after: next)
                case "\\": out.append("\\"); i = s.index(after: next)
                case "\"": out.append("\""); i = s.index(after: next)
                case "n":  out.append("\n"); i = s.index(after: next)
                case "t":  out.append("\t"); i = s.index(after: next)
                case "r":  out.append("\r"); i = s.index(after: next)
                case "u":
                    let hexStart = s.index(after: next)
                    guard let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex),
                          let scalar = UInt32(s[hexStart..<hexEnd], radix: 16),
                          let unicode = Unicode.Scalar(scalar)
                    else { out.append(c); i = s.index(after: i); continue }
                    out.append(Character(unicode))
                    i = hexEnd
                default:
                    out.append(c); i = s.index(after: i)
                }
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
