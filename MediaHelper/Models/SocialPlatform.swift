import Foundation

/// The set of social platforms the app attempts to download from.
///
/// Platform detection is performed by `SocialURLParser` using host-based
/// matching against the URL the user pastes into the Download tab.
enum SocialPlatform: String, CaseIterable, Identifiable, Hashable {
    case youtube
    case twitter
    case tiktok
    case instagram
    case facebook
    case threads
    case streamable
    case unknown

    var id: String { rawValue }

    /// Human-friendly label shown in the UI next to the detected URL.
    var displayName: String {
        switch self {
        case .youtube:   return "YouTube"
        case .twitter:   return "X / Twitter"
        case .tiktok:    return "TikTok"
        case .instagram: return "Instagram"
        case .facebook:  return "Facebook"
        case .threads:    return "Threads"
        case .streamable: return "Streamable"
        case .unknown:    return "Unknown"
        }
    }

    /// SF Symbol shown next to the platform name in the status row.
    var symbol: String {
        switch self {
        case .youtube:   return "play.rectangle.fill"
        case .twitter:   return "bird.fill"
        case .tiktok:    return "music.note.tv.fill"
        case .instagram: return "camera.fill"
        case .facebook:  return "f.square.fill"
        case .threads:    return "bubble.left.and.bubble.right.fill"
        case .streamable: return "play.circle.fill"
        case .unknown:    return "questionmark.circle"
        }
    }
}
