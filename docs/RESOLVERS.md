# Resolvers

How MediaHelper turns a pasted page URL into a direct media URL, per platform.

This document is the source of truth. The iOS implementation in
`MediaHelper/Downloaders/` and any future port should both match what's written
here. When a platform breaks, fix this file first, then make the code match —
that way the knowledge survives in one place instead of being rediscovered per
codebase.

Everything here was extracted from the working Swift implementation. Endpoints,
header names, client version strings, and JSON paths are exact: they are load
bearing, not illustrative.

---

## 1. Contract

A resolver takes a page URL and returns one or more `ResolverResult`:

| Field | Meaning |
|---|---|
| `mediaURL` | Direct URL of the file to download |
| `title` | Display title (video title, tweet text, `@username`) |
| `thumbnailURL` | Preview image, usually `og:image` |
| `isVideo` | `true` for video, `false` for a still |
| `platform` | Which resolver produced this |
| `requestHeaders` | Headers the **downloader** must replay when fetching `mediaURL` |

`requestHeaders` is the subtle one. Some CDNs bind the media URL to the session
that produced it and return 403 if the download request doesn't carry the same
User-Agent, Referer, or cookies as the resolve step. TikTok and Threads set
these today; the downloader forwards them verbatim.

**`resolve` vs `resolveAll`.** `resolve` returns one item, preferring video over
stills. `resolveAll` returns every item in the post and defaults to wrapping
`resolve` in a one-element array. Only Instagram (carousels) and Twitter (up to
four attachments) override it. Both overrides fall back to `resolve` if their
multi-item path fails, so a carousel degrades to its first item rather than
erroring.

**Errors.** `invalidURL`, `unsupportedPlatform`, `resolutionFailed(why)`,
`networkFailed(why)`, `saveFailed(why)`, `loginRequired(platform)`. Only
`loginRequired` drives UI behaviour — it points the user at the Instagram
session-cookie setting.

### Formats deliberately not supported

Progressive single-file MP4 only. No HLS stitching, no DASH.

- YouTube reads `streamingData.formats` (muxed) and ignores `adaptiveFormats`,
  so the ceiling is roughly 720p. Higher resolutions are video-only streams that
  would need muxing with a separate audio stream.
- Twitter filters `content_type == "video/mp4"` and skips `x-mpegURL`.
- Facebook skips any candidate containing `.mpd` or `<MPD`.
- **Live streams return HLS manifests and will fail.** This is expected.

### Timeouts and accepted status codes

15s for HTML page fetches, 12s for YouTube InnerTube calls, 8s for HEAD
redirect probes. HTML fetches accept `200..<400` (some platforms answer a
redirect with a usable body); JSON APIs require `200..<300`.

---

## 2. URL parsing (`SocialURLParser`)

Pure, no network. Prepends `https://` when the scheme is missing.

### Host → platform

Leading `www.`, `m.`, `mobile.`, `vm.`, `vt.` are stripped before matching.

| Platform | Hosts |
|---|---|
| YouTube | `youtube.com`, `youtu.be`, `youtube-nocookie.com` |
| Twitter | `twitter.com`, `x.com`, `t.co` |
| TikTok | `tiktok.com` (covers `vm.`/`vt.` short links) |
| Instagram | `instagram.com` |
| Facebook | `facebook.com`, `fb.com`, `fb.watch` |
| Threads | `threads.net`, `threads.com` |
| Streamable | `streamable.com` |
| Vimeo | `vimeo.com`, `player.vimeo.com` |

### Tracking-param stripping

Share sheets append junk (`si`, `igsh`, `s`, `t`, `ref_src`, `feature`, …).

- **YouTube**: keep only `v`. `youtu.be` links carry the ID in the path, so drop
  the whole query.
- **Facebook**: keep only `v`, and only when the path is exactly `watch`. Every
  other Facebook path carries the ID in the path — drop the whole query.
- **Everything else**: drop the whole query. The ID is always in the path.

### The `@username` trap

Threads URLs look like `/@user/post/SHORTCODE`. Feeding that through
`URLComponents(url:)` can read the `@` as a userinfo separator and corrupt the
host, and even on the benign path it percent-encodes `@` to `%40`, producing a
different URL string for no reason.

Three defences, all worth keeping in any port:

1. If there's no `?` at all, return the URL untouched — no round-trip.
2. Strip the query by slicing the string at the first `?` (re-appending any
   `#fragment`), never by rebuilding components.
3. Read a single query value by parsing `"?" + url.query` in isolation, where
   there's no path for `@` to appear in.

`URLComponents(url:)` is only used on YouTube and Facebook URLs, whose paths
never contain `@`.

Java's `Uri`/`URI` have their own version of this problem. A port needs its own
check against these cases; the JVM unit test table is the cheapest place to keep
it honest.

---

## 3. Shared HTML scraping (`HTMLScraper`)

`metaContent(html, property:)` tries three regex shapes in order, because
attribute order varies and Twitter-card tags use `name=` instead of `property=`:

```
<meta[^>]+property=["']KEY["'][^>]+content=["']([^"']+)["']
<meta[^>]+content=["']([^"']+)["'][^>]+property=["']KEY["']
<meta[^>]+name=["']KEY["'][^>]+content=["']([^"']+)["']
```

All matching is case-insensitive. Captures are HTML-entity decoded for the small
set that shows up in meta tags: `&amp;`, `&quot;`, `&#39;`, `&lt;`, `&gt;`.

### JSON-in-HTML escape decoding

Four resolvers (Instagram, TikTok, Threads, Facebook) scrape `"key":"value"`
out of inlined JSON with a regex rather than parsing it — TikTok's rehydration
blob in particular is far too large to parse for one field. Each then decodes
the JSON escapes by hand: `\/`, `\\`, `\"`, `\uXXXX`, plus `\n` `\t` `\r` in the
TikTok and Facebook variants.

**The generic `\uXXXX` path is required, not a nicety.** TikTok serializes
reserved URL characters as escapes: `\u`+`003F` for `?`, `\u`+`003D` for `=`,
`\u`+`0026` for `&` (written as two pieces here only so the sequence survives
copy/paste through tooling that decodes it). Leave them undecoded and the
resulting string fails URL parsing outright (`URLError.badURL` on iOS). Any port
needs the same decoder before constructing the URL.

Instagram additionally handles a **doubly-escaped** form — `\"key\":\"value\"`
— which its embed page has used since roughly 2025. That path decodes twice.
The regex uses a lazy `[^"]+?` so it stops at the closing `\"` without eating
the backslash.

---

## 4. Instagram

The most complex resolver, and the one that breaks most often. Six passes; the
first one yielding a video wins.

| # | Pass | Needs cookie |
|---|---|---|
| 1 | Private GraphQL API | no |
| 2 | Canonical page, desktop UA | no |
| 3 | Embed page (`/embed/captioned/`) | no |
| 4 | Canonical page, Instagram iOS app UA | no |
| 5 | Private media-info API | **yes** |
| 6 | Give up → `loginRequired` | — |

Pass ordering matters for privacy as well as reliability: the stored session
cookie is only sent after every cookie-free pass has failed, so public posts
never transmit it.

`resolveAll` (carousels) has its own two-step path: GraphQL sidecar first, then
the private API. The embed and OpenGraph surfaces only ever expose the *first*
item of a carousel, so without a session cookie a carousel collapses to one
item. That's a known, accepted limitation.

### Constants

```
doc_id          10015901848480474      ← rotates every few weeks
lsd             AdRajKE-dbL5DFDu4y87RHQZaXA
X-IG-App-ID     936619743392459        ← public, in their JS bundle
X-ASBD-ID       129477
X-IG-Capabilities  3brTvw==
```

> ⚠️ **As of 2026-06 the GraphQL pass is broken** — every known `doc_id` returns
> an execution error. The embed page (pass 3) is the working fallback. Update
> `doc_id` and `lsd` together when it comes back; cross-reference
> `github.com/ahmedrangel/instagram-media-scraper`.

### User agents

Instagram's edge serves different markup per UA, which is why passes 2 and 4
fetch the same URL twice:

- **Desktop Safari 17** — logged-out visitors get a JS-only shell with no media.
- **Instagram iOS app** (`Instagram 250.0.0.21.109 (iPhone14,3; iOS 17_0; …)`)
  — sometimes nudges the server into inlining the media JSON.

### Pass 1 — GraphQL

`POST https://www.instagram.com/api/graphql`

Body is **form-encoded, not JSON**: `doc_id`, `lsd`, `variables={"shortcode":"…"}`.

Headers: `Content-Type: application/x-www-form-urlencoded`, desktop UA,
`X-IG-App-ID`, `X-FB-LSD` (= lsd), `X-ASBD-ID`, `Sec-Fetch-Site: same-origin`,
`Origin: https://www.instagram.com`, `Referer: https://www.instagram.com/`,
`Accept-Language: en-US,en;q=0.9`.

```
data.xdt_shortcode_media
  __typename            XDTGraphSidecar | XDTGraphImage | XDTGraphVideo
  is_video              bool
  video_url             direct mp4
  display_url           full-res still
  owner.username        → title as "@username"
  edge_sidecar_to_children.edges[].node   carousel children, same field shape
```

An empty or missing `data` object is the signal that `doc_id` has rotated.

### Pass 3 — Embed page

`GET https://www.instagram.com/p/<shortcode>/embed/captioned/`

Logged-out-only surface: it never honours a session cookie, so don't send one.
It decides per-post whether to inline the video based on the post's sensitivity;
gated posts fall through to pass 5.

Video keys in preference order — Instagram has shipped at least three shapes —
`video_url`, `videoUrl`, `contentUrl` (JSON-LD); then `og:video` /
`og:video:secure_url`; then `display_url` for stills. Title comes from
`<div class="CaptionUsername">…</div>`, falling back to `og:title`.

### Passes 2 and 4 — Canonical page

`og:video` / `og:video:secure_url`, then an inline key sweep in preference
order: `playable_url_quality_hd`, `playable_url`, `video_url`, `videoUrl`,
`contentUrl`. Then the first `"url":"…"` appearing after the literal anchor
`"video_versions":[`. Then a brute-force scan for any `https://…mp4`. Then
`og:image` as a still, last resort.

### Pass 5 — Private media-info API

`GET https://i.instagram.com/api/v1/media/<mediaID>/info/`

**Must be `i.instagram.com`, not `www`** — `www.instagram.com/api/v1` redirect
loops on authenticated requests.

Headers: Instagram iOS app UA, `X-IG-App-ID`, `X-IG-Capabilities: 3brTvw==`,
`Cookie: sessionid=<stored>`.

```
items[0]
  user.username                       → "@username"
  carousel_media[]                    carousel children, in post order
  video_versions[0].url               highest-quality video
  image_versions2.candidates[0].url   still / thumbnail
```

Any non-2xx (401, 403, or a 302 to login) means the cookie is expired or invalid
→ `loginRequired`. Note the asymmetry: when a cookie *is* present and this pass
fails, the resolver raises `loginRequired` immediately rather than continuing —
a bad cookie is worth reporting, not working around.

### Shortcode → media ID

Instagram shortcodes are the media primary key in URL-safe base64. To hit the
private API you need the numeric PK:

```
alphabet = A–Z a–z 0–9 - _        (index = digit value, base 64)
id = 0; for each char: id = id * 64 + index(char)
```

Return nothing on an unknown character or on 64-bit overflow. A port must use an
unsigned 64-bit accumulator with overflow detection — Kotlin's `ULong` with
explicit checks, not `Long`.

### Shortcode extraction

Path must start with `p`, `reel`, `reels`, or `tv`; the next component is the
shortcode, valid only if it's entirely `[A-Za-z0-9_-]`.

`pathImpliesVideo` is true for `reel`, `reels`, `tv` but **not** `p` — a `/p/`
post may legitimately be a photo, so "no video found" is only an error on the
reel-style paths.

---

## 5. YouTube

Uses the private **InnerTube** API, the same approach as yt-dlp and cobalt.
Google blocks clients selectively, so several are tried in order.

Two endpoints, tried per client:

```
1. https://www.youtube.com/youtubei/v1/player?prettyPrint=false        (no key)
2. https://youtubei.googleapis.com/youtubei/v1/player
     ?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false
```

### Client table

Versions current as of April 2026, cross-referenced with
`alexeichhorn/YouTubeKit`. **Transcribe exactly** — version strings are part of
what gets fingerprinted.

| Order | Client | ID | Version | Why it's in the list |
|---|---|---|---|---|
| 1 | `ANDROID_VR` | 28 | `1.65.10` | Meta Quest app; **PoToken-exempt** per the yt-dlp wiki |
| 2 | `ANDROID` | 3 | `20.10.38` | Main consumer client; most stable for public videos |
| 3 | `MWEB` | 2 | `2.20250925.01.00` | Mobile web; lightweight, often PoToken-free |
| 4 | `WEB_EMBEDDED_PLAYER` | 56 | `1.20260115.01.00` | Embed surface, sometimes more permissive |
| 5 | `TVHTML5_SIMPLY_EMBEDDED_PLAYER` | 85 | `2.0` | Handles age-gated content |
| 6 | `IOS` | 5 | `20.10.4` | Final fallback; increasingly needs a PoToken |

User agents:

```
ANDROID_VR   com.google.android.apps.youtube.vr.oculus/1.65.10
             (Linux; U; Android 12L; en_US; Quest 3) gzip
ANDROID      com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip
MWEB         Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_2 like Mac OS X)
             AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.2
             Mobile/15E148 Safari/604.1
WEB_EMBEDDED Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36
             (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36
TVHTML5      Mozilla/5.0 (PlayStation; PlayStation 4/8.03) AppleWebKit/605.1.15
             (KHTML, like Gecko) Version/13.0 Safari/605.1.15
IOS          com.google.ios.youtube/20.10.4
             (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)
```

Per-client context extras, merged into `context.client`:

```
ANDROID_VR  deviceMake=Oculus, deviceModel=Quest 3, androidSdkVersion=32,
            osName=Android, osVersion=12L
ANDROID     androidSdkVersion=30, osName=Android, osVersion=11
IOS         deviceModel=iPhone16,2, osName=iPhone OS, osVersion=18.3.2,
            userInterfaceIdiom=handset
MWEB, WEB_EMBEDDED_PLAYER, TVHTML5_SIMPLY_EMBEDDED_PLAYER — none
```

### Request

```json
{ "context": { "client": {
      "clientName": "<name>", "clientVersion": "<version>",
      "hl": "en", "gl": "US", "timeZone": "UTC", "utcOffsetMinutes": 0
      /* + per-client extras */ } },
  "videoId": "<id>", "contentCheckOk": true, "racyCheckOk": true }
```

Headers: `Content-Type: application/json`, per-client UA, `Accept-Language:
en-US,en;q=0.9`, `X-Youtube-Client-Name: <numeric id>`,
`X-Youtube-Client-Version: <version>`, `Origin: https://www.youtube.com`,
`Referer: https://www.youtube.com/`.

`contentCheckOk` and `racyCheckOk` suppress the "this content may be
inappropriate" interstitial.

### Response

```
playabilityStatus.status                 must be "OK", else surface .reason
streamingData.formats[]                  progressive (muxed) only
videoDetails.title
videoDetails.thumbnail.thumbnails[last].url
```

Format selection: keep entries whose `mimeType` contains both `video/` and a
comma (the comma is what marks a muxed audio+video stream); pick max `height`,
tie-breaking toward `mp4`.

When every client fails, surface the *last* error — it usually carries YouTube's
own wording ("Sign in to confirm you're not a bot", "Video unavailable"), which
is far more useful to the user than a generic message.

### Video ID extraction

`youtu.be/<id>`, `/watch?v=<id>`, `/shorts/<id>`, `/embed/<id>`, `/live/<id>`,
`/v/<id>`. Sanitize by splitting on `?`, `&`, `#`, then require at least 11
characters of `[A-Za-z0-9_-]` and take the first 11.

### Known limits

PoToken-gated videos that block every client need a JS engine to solve
BotGuard/DroidGuard — out of scope. Live streams return HLS.

---

## 6. TikTok

Scrapes the `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">` blob on the
public watch page. Two mechanics do the real work here.

**A cookie jar scoped to this one resolve.** The landing page sets `ttwid`,
`tt_chain_token`, and friends, and the video CDN validates them later. iOS uses
an ephemeral `URLSession` so the jar doesn't leak across the app; the cookies are
then flattened into a `Cookie:` header on the result so the download request
replays them. A port needs a per-resolve OkHttp `CookieJar` — the shared client's
jar is not equivalent, and reusing it across resolves risks sending one video's
tokens with another's download.

**Manual redirect following.** `vm.tiktok.com` / `vt.tiktok.com` short links
redirect to `/@user/video/<id>`. TikTok sometimes puts unencoded reserved
characters in the `Location` header, which strict URL parsers reject outright.
So: up to 5 hops, `HEAD` requests, automatic redirects disabled, each `Location`
re-encoded through a components round-trip before continuing.

Landing-page fetch: desktop Safari 17 UA, `Accept-Language: en-US,en;q=0.9`.

Media keys in preference order — `playAddr_h264` (watermark-free), `playAddr`,
`downloadAddr` — then `og:video` / `og:video:url` as a last resort.

### Headers returned for the download

```
User-Agent:  <the same desktop Safari 17 string>
Referer:     https://www.tiktok.com/
Range:       bytes=0-
Cookie:      <flattened jar; header dropped entirely if empty>
```

All four matter. TikTok's CDN 403s without them — this is the original reason
`requestHeaders` exists on `ResolverResult`.

---

## 7. X / Twitter

`GET https://cdn.syndication.twimg.com/tweet-result?id=<id>&token=<token>&lang=en`

This is the JSON feed behind embeddable tweet widgets. No login, no bearer
token, and it treats `twitter.com` and `x.com` identically.

Headers: desktop Safari 17 UA, `Referer: https://platform.twitter.com`.

### The token

Replicates the JS in Twitter's widget loader:

```js
((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "")
```

Fall back to the literal `"a"` if the ID won't parse. Tweet IDs exceed double
precision, but only the leading digits matter — the server accepts any token
derived from this formula. The Swift side hand-rolls a base-36 formatter to
match JS `Number#toString(36)`: integer part, then `.`, then up to 11 fractional
digits, stopping early once the remainder hits zero. A port must reproduce the
same digit sequence, so port the formatter rather than reaching for a language
built-in that may round differently.

### Response

```
text                          → title (falls back to user.name)
mediaDetails[]                one entry per attachment, in author order
  type                        "photo" | "video" | "animated_gif"
  media_url_https             still / thumbnail
  video_info.variants[]       { content_type, bitrate, url }
```

Filter variants to `content_type == "video/mp4"` and pick max `bitrate`, which
skips the `application/x-mpegURL` HLS entry. `animated_gif` is served as MP4 and
handled on the video path.

`resolveAll` returns every entry in order, interleaving photos and videos as the
author attached them. `resolve` prefers the first video, else the first item.

### Fallback and known gap

OpenGraph scrape, rewriting `x.com` → `twitter.com` first.

Protected and age-gated tweets return a `tombstone` instead of media. Handling
them would need a guest-token GraphQL call; not implemented.

---

## 8. Threads

Threads runs on Instagram's infrastructure and server-renders posts for
logged-out visitors **on `threads.net`**. The `threads.com` domain may serve a
client-side-only shell with no media in the initial HTML, so URLs are normalised
to `.net` before fetching, with `.com` as a second try, then the embed page
`https://www.threads.net/t/<shortcode>/embed/`.

### The two non-obvious rules

**UA order is deliberate.** Chrome first, iOS Safari second, Googlebot last:

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36
  (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36
Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15
  (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1
Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)
```

The CDN URLs baked into the HTML carry session tokens tied to the fetching
context. Chrome-fetched URLs download fine from a Chrome-like request. Googlebot
gets the most complete SSR page (Meta whitelists it for SEO) but its CDN URLs
can be bound to Googlebot's context and 403 for a real client — so it's a
last-resort page fetch, not a first choice. Whichever UA won the page fetch is
returned in `requestHeaders` and replayed on the download.

**Don't stop at the first HTTP 200.** Some UAs get a JS-only shell that returns
200 with no media in it. Each UA must be run through the *full extraction
pipeline*; stop at the first UA whose HTML actually yields media. Iterating
until a 200 and then extracting is a real bug that looks like it works.

Page-fetch headers: UA, `Accept: text/html,application/xhtml+xml,application/
xml;q=0.9,image/webp,*/*;q=0.8`, `Accept-Language: en-US,en;q=0.9`,
`Upgrade-Insecure-Requests: 1`, `Cache-Control: no-cache`.

### Extraction order

1. `og:video`, `og:video:secure_url`, `og:video:url`
2. Video key sweep: `video_url`, `playable_url`, `playable_url_quality_hd`,
   `playback_url`, `stream_url`, `clip_playback_url` (Threads Clips), `videoUrl`,
   `contentUrl`, `browser_native_url`
3. `"video_versions": [ … "url": "…" ]` — first URL in the array
4. `<source src="….mp4">` / `<video src="….mp4">` / `<source src="…" type="video…">`
5. Brute-force `https://…mp4` scan
6. Image key sweep: `display_url`, `image_url`, `thumbnail_url`
7. Brute-force scan restricted to `scontent*` hosts (user uploads) for
   `jpg|jpeg|png|webp`
8. `og:image`, only if it survives the non-media filter

Every key sweep collects **all** matches and takes the first that passes the
non-media filter — not the first match. Profile pictures and UI assets appear
earlier in the HTML than post media, so first-match-wins downloads the author's
avatar instead of the post.

### Non-media URL filter

Reject any candidate containing:

```
static.cdninstagram.com    Meta's static UI assets (user content is scontent*)
rsrc.php                   Facebook static resource CDN
t51.2885-19                Instagram CDN asset type for profile pictures
profile_pic, profile_pics
/s150x150/, /s320x320/     fixed-size avatar renditions
```

### Headers returned for the download

```
Referer:          <the page URL that was scraped>
User-Agent:       <the UA that successfully fetched that page>
Accept:           video/mp4,video/webm,video/*;q=0.9,image/avif,image/webp,
                  image/*;q=0.8,*/*;q=0.5
Accept-Language:  en-US,en;q=0.9
Origin:           https://www.threads.net
```

The CDN checks `Referer` and the `_nc_sid` session token against the fetching
UA; mismatching either gives a 403.

### Shortcode extraction

Component after `post` (`/@user/post/SHORTCODE`), or component `[1]` when the
path starts with `t` (`/t/SHORTCODE`).

Private posts require login; not supported.

---

## 9. Facebook

Public videos only. Four passes, stopping at the first that yields a video:

1. Canonical desktop page — richest `og:` tags and inlined JSON
2. `m.facebook.com` with a mobile UA — simpler server-side markup
3. `https://www.facebook.com/video/embed?video_id=<id>` — the third-party iframe
   surface. Facebook keeps it scrape-friendly because it cannot require login
   from embedding sites, which makes it the most reliable of the four.
4. Desktop again, this time accepting a still

Each pass runs the same extraction: `og:video:secure_url` → `og:video` →
`og:video:url`; then an inline JSON key sweep in quality order:

```
hd_src, sd_src
browser_native_hd_url, browser_native_sd_url
playable_url_quality_hd, playable_url
videoUrl, video_url
hd_src_no_ratelimit, sd_src_no_ratelimit
dash_manifest              (rarely a direct URL, but cheap to try)
```

Candidates containing `.mpd` or `<MPD` are skipped — those are DASH manifests,
not files. Then a brute-force `https://…mp4` scan.

The still fallback is deliberately conservative: return `og:image` only when the
page has an `og:image`, **no** `og:video`, and no occurrence of `mp4` anywhere
in the HTML. Any hint of video means a video pass should have worked, and
handing back a thumbnail would mask the real failure.

### Video ID extraction

Numeric `?v=` (covers `/watch/?v=` and `/video.php?v=`); or the component after
`videos`, `reel`, or `reels`; or `/video/<id>/`. All must be all-digits.
`fb.watch` short links get a single `HEAD` hop to read `Location` — one hop is
enough, they redirect straight to canonical.

User agents: desktop Safari 17, and iOS Safari 17 for the mobile pass.

No `requestHeaders` are set — Facebook's video CDN currently serves the resolved
URL to a bare request. If that changes, the Threads resolver is the pattern to
copy.

Authenticated/private content would need the user's `c_user` + `xs` cookies
captured through an in-app WebView. Out of scope; it fails cleanly.

---

## 10. Vimeo

`GET https://player.vimeo.com/video/<id>/config`, plus `?h=<hash>` for unlisted
videos shared by link.

Headers: `Referer: https://vimeo.com/`, desktop Safari 17 UA.

```
video.title
video.thumbs.base           → thumbnail
files.progressive[]         { url, width } — pick max width
```

401 or 403 means private or password-protected — surfaced as that, specifically,
rather than a generic network error. An empty `files.progressive` usually also
means restricted.

URL forms: `vimeo.com/<id>`, `vimeo.com/<id>/<hash>`,
`vimeo.com/channels/<name>/<id>`, `vimeo.com/groups/<name>/videos/<id>`,
`player.vimeo.com/video/<id>`.

The ID is the first all-digit path component of at least 5 characters. The hash
is the component immediately after it, accepted only if it's all hex digits and
**not** all decimal digits — otherwise a second numeric path segment gets
misread as a hash.

---

## 11. Streamable

The easy one. `GET https://api.streamable.com/videos/<shortcode>`, no headers
required.

```
title
thumbnail_url
files.mp4.url           preferred
files.mp4-mobile.url    fallback
```

URLs come back protocol-relative (`//cdn…`) and need `https:` prepended.
Shortcode is the last path component.

---

## 12. Things that expire

Everything here is a live dependency on someone else's private API. In rough
order of how often it has needed attention:

| Constant | Where | Symptom when stale |
|---|---|---|
| Instagram `doc_id` | `InstagramResolver` | GraphQL returns empty `data` / execution error |
| Instagram `lsd` | `InstagramResolver` | Update together with `doc_id` |
| YouTube client versions | `YouTubeResolver` client table | "Sign in to confirm you're not a bot" on every client |
| YouTube API key | `apiEndpoint` | 400/403 from `youtubei.googleapis.com` |
| TikTok `playAddr` key names | `TikTokResolver` | "didn't expose playAddr/og:video" |
| Threads video key names | `ThreadsResolver` extraction list | Falls through to the avatar or fails |
| Instagram session cookie | Keychain / user setting | `loginRequired` on posts that previously worked |
| User-Agent strings | all resolvers | Gradual: a pass that used to work starts returning shells |

## 13. Triage

| Symptom | Look at first |
|---|---|
| Resolve works, download 403s | `requestHeaders` — UA/Referer/Cookie mismatch between resolve and download |
| Got the author's profile picture instead of the post | Non-media filter, or a key sweep taking first-match instead of first-passing-match |
| Carousel gives only the first item | GraphQL pass is down and no session cookie is stored — expected |
| Instagram video path finds nothing | Usually a login-gated post, not a code bug; check `doc_id` first |
| URL rejected as malformed before any request | JSON `\uXXXX` escapes left undecoded (TikTok), or `@` in path mangled by a components round-trip (Threads) |
| Live stream fails | Expected — HLS is not supported |
| Only 720p from YouTube | Expected — progressive `formats` only, `adaptiveFormats` unused |
| Everything fails on one platform, suddenly | Check the expiry table above before reading code |
