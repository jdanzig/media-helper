import Foundation

/// Inspects a string the user has pasted and decides which social platform
/// (if any) it belongs to. Pure value-in / value-out — no network calls.
struct SocialURLParser {

    /// Normalize a user-typed string into a URL if at all possible.
    /// Tolerates missing scheme ("youtube.com/watch?v=…") by prepending https.
    static func url(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        return URL(string: "https://" + trimmed)
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
        default:
            return .unknown
        }
    }
}
