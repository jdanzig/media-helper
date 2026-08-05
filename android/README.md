# MediaHelper — Android

Jetpack Compose rewrite of the iOS app, mirroring its five tabs
(Download / Transcribe / Stitch / Squarify / Settings).

**Status: scaffold only.** The tab shell builds and runs; no features are
implemented yet. They land one at a time, using [../docs/RESOLVERS.md](../docs/RESOLVERS.md)
as the shared spec for the download resolvers.

## Building

Open the `android/` folder in Android Studio and let it sync Gradle, then run
on an emulator or device (minSdk 26).

The Gradle wrapper JAR (`gradle/wrapper/gradle-wrapper.jar`) is intentionally
not committed — Android Studio regenerates it on first sync, or run
`gradle wrapper` if you have a local Gradle. Everything else (version catalog,
build scripts, manifest) is in place.
