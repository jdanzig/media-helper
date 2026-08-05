# MediaHelper

A personal utility for downloading social media content, transcribing videos, stitching images together, and squarifying photos for square-format posts.

This is a monorepo holding two near-identical native apps that mirror each other's features:

```
ios/      SwiftUI app (iOS 17+, Xcode)
android/  Jetpack Compose app (Kotlin, Android Studio)
docs/     Shared, platform-agnostic specs — start with RESOLVERS.md
```

## Features

Both apps offer the same five tabs:

### Download

Paste a URL from YouTube, X/Twitter, TikTok, Instagram, Facebook, Threads, Streamable, or Vimeo. The app downloads the media (including Instagram carousels) and optionally runs transcription on it. Downloaded files can be shared or saved to the photo library. Some platforms gate content behind a login — paste a session cookie in Settings to unlock those.

Each platform is resolved differently, and those strategies go stale when the platforms change. [docs/RESOLVERS.md](docs/RESOLVERS.md) documents the per-platform endpoints, required headers, JSON paths, and known failure modes — it's the shared source of truth both apps implement, so start there when a download breaks.

### Transcribe

Pick a video, choose output formats (`.srt` subtitles, `.txt` transcript, save to library), select a transcription backend, and run it. Results are offered via the share sheet.

### Stitch

Combine up to 20 images into a single composite (vertical or horizontal), with reordering, an optional divider line, and pinch/pan preview.

### Squarify

Make a rectangular image square by adding a solid background border matching the image's top-left pixel color — the approach Instagram uses for non-square photos.

## Building

- **iOS** — open `ios/MediaHelper.xcodeproj` in Xcode, pick a simulator or device on iOS 17+, and build (`⌘B`) / run (`⌘R`). No package manager setup required.
- **Android** — open the `android/` folder in Android Studio and let it sync Gradle, then run on an emulator or device.
