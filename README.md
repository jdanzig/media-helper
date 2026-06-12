# MediaHelper

A personal iOS utility for downloading social media content, transcribing videos, stitching images together, and squarifying photos for square-format posts.

## Requirements

- iOS 17+
- Xcode 15+

## Features

### Download

Paste a URL from YouTube, X/Twitter, TikTok, Instagram, Facebook, Threads, or Streamable. The app downloads the media (including Instagram carousels) and optionally runs transcription on it. Downloaded files can be shared or saved directly to Photos.

### Transcribe

Pick a video from your Photo Library. Choose output formats (`.srt` subtitles, `.txt` transcript, save to Photos), select a backend, and tap Start. Results are offered via the share sheet.

### Stitch

Combine multiple images into a single composite image.

- Pick up to 20 images from Photos (ordered selection)
- Choose vertical (stacked) or horizontal (side-by-side) layout
- Toggle a 1px divider line between images
- Reorder images by long-pressing a thumbnail and dragging it left or right
- Remove individual images with the × button on each thumbnail
- Pinch/pan the preview; save the result to Photos

Vertical stitch normalizes all images to the narrowest width; horizontal normalizes to the shortest height.

### Squarify

Make a rectangular image square by adding a solid background border, matching the color of the image's top-left pixel — the same approach Instagram uses for portrait/landscape photos posted to a square grid.

- Pinch to zoom (minimum: fit-inside-canvas; maximum: 6× fit)
- Drag to reposition
- Reset position button
- Save the composited square image to Photos

## Building

Open `MediaHelper.xcodeproj` in Xcode, select a simulator or device running iOS 17+, and build (`⌘B`) or run (`⌘R`).

No external dependencies or package manager setup required.
