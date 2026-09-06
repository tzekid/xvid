# Instagram source

This source retrieves public, logged-out posts and Reels. It is not an official
Meta API or a universal Instagram archiver. No user-account cookies, passwords,
FastDL endpoint, yt-dlp executable, browser automation or JavaScript interpreter
are used in production.

## Protocol provenance

Reviewed 2026-09-06 against:

- Instaloader `structures.py` / `instaloadercontext.py`: shortcode web-info
  `doc_id=27128499623469141`, `xdt_api__v1__media__shortcode__web_info.items`.
- yt-dlp `extractor/instagram.py`: current public-page/Relay response structures,
  video-versus-poster distinction and `video_versions`/DASH quality differences.
- Cobalt's Instagram implementation: behavioural reference for per-child pickers
  and same-origin thumbnail delivery; no Cobalt implementation was copied.

The implementation first inspects identity-matched JSON embedded in the
canonical post page. It then tries one bootstrapped shortcode GraphQL request,
using only anonymous CSRF/LSD values from that page. Query constants belong in
`src/instagram.zig`. If Instagram changes them, update the parser/query together
with fixtures and live evidence. Never add a chain of speculative old endpoints.

Ordinary Zig HTTPS is used. Instagram can require a browser transport,
authentication or a challenge even for apparently public links, particularly
from datacenter networks. These conditions produce explicit errors, not a
misleading cover-image download. A passing fixture suite does NOT prove live
Instagram access from the production VPS. Verify representative public links
from that VPS before claiming provider coverage; no live-coverage percentage is
claimed by this change.

## Product contract

- A single image/video starts automatically in Basic mode.
- A carousel enters `awaiting_choice`; the user selects one stable child ID.
- Only that child's full-size file is requested. Other children may have small
  lazy previews, but are never preloaded at full size.
- Unknown/unavailable children retain their positions. A missing video URL does
  not convert the node to an image. An incomplete carousel cannot become its cover.
- `/reel/` does not determine type. Payload structure determines collection type.
- `img_index` is only a visual hint, not an automatic download selection.
- One stale-media refresh is allowed. Recovery uses the same child ID and kind,
  never the same numeric position in a reordered response.
- Original preserves the best direct candidate returned by this retrieval path.
  It does not promise camera originals, or parity with higher-quality authenticated
  or DASH-only renditions. No lossy conversion is added.
- Stories, Highlights, private accounts, audio extraction, bulk download and
  carousel video previews are outside this release.

## Bounds and privacy

Up to 32 discovered children, one selected artifact; X's eight-output bound is
unchanged. Metadata is capped at 4 MiB, media URLs at 4096 bytes, and thumbnails
at 256 KiB. At most two preview routes are active, with at most the first sixteen
thumbnails cached per job (4 MiB). Media-host validation is repeated on redirects.
Only reviewed `cdninstagram.com` and `fbcdn.net` host boundaries are accepted.
An exact loopback origin exists for deterministic tests, not an arbitrary proxy.

Plans and their signed media URLs exist only inside private temporary job
manifests. `inspect`, HTML, usage records and logs do not expose them. Thumbnail
URLs are job/item-ID routes. Instagram receives no X token or account cookies.

The additive plan/selection fields default to null when loading older X jobs;
existing X jobs and durable usage records remain intact. Do not roll an older
binary back over new Instagram jobs without draining/quarantining those temporary
jobs first. Never remove `usage.sqlite3` to clear media jobs.

## Verification

`zig build test -Doptimize=ReleaseSafe` tests URL/model/parser/renderer invariants.
`zig build e2e -Doptimize=ReleaseSafe` retains the existing X journeys and adds
`tests/instagram_e2e.py`, a standard-library fixture server driving the real
binary. Python is test tooling only (already required by the X E2E runner).
The Instagram suite generates a real H.264/AAC MP4 with FFmpeg, compares delivered
bytes and Range responses, and asserts the upstream request ledger.

The decisive regression is: selecting slide 7 never requests the originals for
slides 1–6 or 8–12, including after a restart or a metadata refresh that reorders
children. Test account/challenge/429/incomplete/invalid-file results separately.

For manual iPhone qualification: single photo, single video, mixed carousel,
large selected video, app background/return, a stale picker and Photos sharing.
Browser share completion means a system share handoff, not verified Photos import.

Use `xvid instagram-probe <url> [--config PATH] --json` for safe live diagnostics.
It prints item types, counts, dimensions and availability, never media URLs.
