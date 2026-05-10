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
    ///  - **Unknown / short-links** (fb.watch, youtu.be, t.co, vm.tiktok.com):
    ///    strip all query params; the meaningful part is the path.
    static func stripTrackingParams(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        let platform = detectPlatform(url)
        switch platform {
        case .youtube:
            // youtu.be short links have the ID in the path, not ?v=
            let isShortLink = url.host?.lowercased().hasSuffix("youtu.be") == true
            if isShortLink {
                comps.queryItems = nil
            } else {
                let v = comps.queryItems?.first(where: { $0.name == "v" })
                comps.queryItems = v.map { [$0] }
            }
        case .twitter:
            comps.queryItems = nil
        case .tiktok:
            comps.queryItems = nil
        case .instagram:
            comps.queryItems = nil
        case .threads:
            comps.queryItems = nil
        case .facebook:
            // /watch/?v=<id> — keep only v; all other paths have ID in path.
            let pathIsWatch = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                      .lowercased() == "watch"
            if pathIsWatch {
                let v = comps.queryItems?.first(where: { $0.name == "v" })
                comps.queryItems = v.map { [$0] }
            } else {
                comps.queryItems = nil
            }
        case .unknown:
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
