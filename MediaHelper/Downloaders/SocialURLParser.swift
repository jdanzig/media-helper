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
        // IMPORTANT: Do NOT use `URLComponents(url:)` here. For URLs whose
        // path contains `@` (e.g. Threads: `/@username/post/ID`), the RFC 3986
        // authority parser can misinterpret `@` as a userinfo separator and
        // set `host` to the substring after `@`, corrupting the reconstructed
        // URL. Instead, build URLComponents manually from URL's already-parsed
        // properties, which are always correct.
        var comps = URLComponents()
        comps.scheme   = url.scheme
        comps.user     = url.user
        comps.password = url.password
        comps.host     = url.host
        comps.port     = url.port
        comps.path     = url.path
        comps.fragment = url.fragment
        // Parse the existing query string into items so we can selectively
        // preserve them for platforms that need a query parameter (e.g. YouTube ?v=).
        let existingItems = url.query.flatMap {
            URLComponents(string: "?\($0)")?.queryItems
        }

        let platform = detectPlatform(url)
        switch platform {
        case .youtube:
            // youtu.be short links have the ID in the path, not ?v=
            let isShortLink = url.host?.lowercased().hasSuffix("youtu.be") == true
            if isShortLink {
                comps.queryItems = nil
            } else {
                let v = existingItems?.first(where: { $0.name == "v" })
                comps.queryItems = v.map { [$0] }
            }
        case .facebook:
            // /watch/?v=<id> — keep only v; all other paths have ID in path.
            let pathIsWatch = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                      .lowercased() == "watch"
            if pathIsWatch {
                let v = existingItems?.first(where: { $0.name == "v" })
                comps.queryItems = v.map { [$0] }
            } else {
                comps.queryItems = nil
            }
        default:
            // Twitter, TikTok, Instagram, Threads, unknown — strip all params.
            comps.queryItems = nil
        }
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
        case "threads.net":
            return .threads
        default:
            return .unknown
        }
    }
}
