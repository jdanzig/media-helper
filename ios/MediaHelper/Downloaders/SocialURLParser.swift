import Foundation

/// Inspects a string the user has pasted and decides which social platform
/// (if any) it belongs to. Pure value-in / value-out — no network calls.
struct SocialURLParser {

    /// Normalize a user-typed string into a URL if at all possible.
    /// Tolerates missing scheme ("youtube.com/watch?v=…") by prepending https.
    /// Strips tracking / sharing query params that social platforms append
    /// when you copy a link (e.g. `si=`, `igsh=`, `s=`, `feature=`).
    static func url(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base: URL?
        if let u = URL(string: trimmed), u.scheme != nil { base = u }
        else { base = URL(string: "https://" + trimmed) }
        return base.map(stripTrackingParams)
    }

    /// Remove platform-specific tracking / share-sheet query parameters.
    ///
    /// Rules per platform:
    ///  - **YouTube**: keep only `v` (the video ID). Everything else
    ///    (`si`, `feature`, `t`, `pp`, `list`, `ab_channel`, …) is noise.
    ///  - **TikTok**: video ID is in the path — strip all query params.
    ///  - **Instagram**: shortcode is in the path — strip all query params
    ///    (`igsh`, `utm_source`, …).
    ///  - **X / Twitter**: tweet ID is in the path — strip all query params
    ///    (`s`, `t`, `ref_src`, …).
    ///  - **Facebook /watch/?v=**: keep `v`; strip everything else (`ref`, …).
    ///    For all other FB paths the video ID is in the path — strip all.
    ///  - **Threads**: `@username` in the path confuses `URLComponents(url:)`
    ///    — it can misparse `@` as a userinfo separator and corrupt the host.
    ///    Build components from the URL's already-parsed properties instead.
    ///  - **Unknown / short-links** (fb.watch, youtu.be, t.co, vm.tiktok.com):
    ///    strip all query params; the meaningful part is the path.
    static func stripTrackingParams(_ url: URL) -> URL {
        // Fast path: if there's no query string there's nothing to strip.
        // Returning the original URL avoids any URLComponents round-trip,
        // which is important for Threads URLs whose path contains `@username`
        // — URLComponents can percent-encode that `@` to `%40`, changing the
        // URL string unnecessarily and triggering a spurious clipboard write.
        guard url.query != nil else { return url }

        let platform = detectPlatform(url)

        switch platform {
        case .youtube:
            // youtu.be short links have the ID in the path, not ?v=.
            if url.host?.lowercased().hasSuffix("youtu.be") == true {
                return removeQuery(from: url)
            }
            // Full YouTube URLs: keep only the video-ID parameter.
            if let v = queryValue("v", in: url) {
                return replaceQuery(in: url, with: [URLQueryItem(name: "v", value: v)])
            }
            return removeQuery(from: url)

        case .facebook:
            // /watch/?v=<id> — keep only v; all other FB paths carry the ID in the path.
            let pathIsWatch = url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased() == "watch"
            if pathIsWatch, let v = queryValue("v", in: url) {
                return replaceQuery(in: url, with: [URLQueryItem(name: "v", value: v)])
            }
            return removeQuery(from: url)

        default:
            // Twitter, TikTok, Instagram, Threads, unknown — drop the entire query.
            return removeQuery(from: url)
        }
    }

    // MARK: - Private query helpers

    /// Strip the query string using string slicing rather than URLComponents.
    /// URLComponents re-parses the full URL string and can misinterpret `@`
    /// in a path segment (e.g. Threads `/@username/post/ID`) as a userinfo
    /// separator, corrupting the host. Slicing at the `?` character is safe.
    private static func removeQuery(from url: URL) -> URL {
        let s = url.absoluteString
        guard let cut = s.firstIndex(of: "?") else { return url }
        // Preserve any fragment that follows the query.
        let fragment = url.fragment.map { "#\($0)" } ?? ""
        return URL(string: String(s[..<cut]) + fragment) ?? url
    }

    /// Return the decoded value of the first query item with the given name.
    private static func queryValue(_ name: String, in url: URL) -> String? {
        guard let q = url.query else { return nil }
        // Parse only the query string — no risk of @ misinterpretation here.
        return URLComponents(string: "?\(q)")?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    /// Replace the URL's entire query string with `items`.
    /// Only called for YouTube / Facebook, whose paths never contain `@`,
    /// so URLComponents(url:) is safe to use.
    private static func replaceQuery(in url: URL,
                                     with items: [URLQueryItem]) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Classify a URL by host. Matching is permissive (strips a leading
    /// "www." / "m." / "mobile.") so that common share-sheet URLs work.
    static func detectPlatform(_ url: URL) -> SocialPlatform {
        guard var host = url.host?.lowercased() else { return .unknown }
        for prefix in ["www.", "m.", "mobile.", "vm.", "vt."] {
            if host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        }

        switch host {
        case "youtube.com", "youtu.be", "youtube-nocookie.com":
            return .youtube
        case "twitter.com", "x.com", "t.co":
            return .twitter
        case "tiktok.com":
            return .tiktok
        case "instagram.com":
            return .instagram
        case "facebook.com", "fb.com", "fb.watch":
            return .facebook
        case "threads.net", "threads.com":
            return .threads
        case "streamable.com":
            return .streamable
        case "vimeo.com", "player.vimeo.com":
            return .vimeo
        default:
            return .unknown
        }
    }
}
