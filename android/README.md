# MediaHelper — Android

Jetpack Compose port of the iOS app, mirroring its five tabs
(Download / Transcribe / Stitch / Squarify / Settings). Shares
[../docs/RESOLVERS.md](../docs/RESOLVERS.md) as the resolver spec.

## Status

| Feature | State |
|---|---|
| Download (8 platforms, carousels, gated posts) | Ported — OkHttp resolvers per `RESOLVERS.md` |
| Save to gallery | Ported — MediaStore (API 29+) |
| Settings (API keys + IG/TikTok cookies) | Ported — SecureStore |
| Squarify | Ported (interactive pan/zoom omitted) |
| Stitch | Ported (drag-reorder omitted; order = selection) |
| Transcribe — OpenAI Whisper & AssemblyAI | Ported (audio extracted via MediaMuxer) |
| Transcribe — on-device Whisper | **Stub** (needs bundled whisper.cpp + JNI) |
| Burn-in subtitles | **Not ported** (needs a MediaCodec pipeline) |

Deliberate simplifications are tagged with `ponytail:` comments in the source.

## Building

Open the `android/` folder in Android Studio and let it sync Gradle, then run
on an emulator or device (minSdk 29).

> **Not yet compiled.** This port was written without an Android SDK in the
> authoring environment, so it has not been through the Kotlin compiler. Expect
> to fix a few compile errors on first build in Android Studio. The
> Gradle wrapper JAR regenerates on first sync.
