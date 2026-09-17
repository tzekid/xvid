# xvid

xvid is a small, mobile-first utility for saving photos and videos from public
X/Twitter status links and public Instagram posts/Reels.

Production is one Zig executable behind Caddy. For X originals, it resolves metadata
and returns the selected media links. The browser fetches the files directly from
X's reviewed CDN hosts, without sending video bytes through the VPS or staging
media on its disk. Instagram retains its existing server download path.
The explicit conversion API remains available for older clients. Jobs are temporary
filesystem directories; normalized usage records live in SQLite.

## User journeys

- **Basic:** paste a link, automatically download the best source media, then
  save or share it. There is no format-choice screen.
- **Choose resolution:** enable the switch, then Paste or Download the current
  link. Tap a source resolution to download that rendition without re-encoding.
  Posts with no resolution choice continue automatically.

Instagram carousels first show an ordered picker. Tap **Save this photo/video**
to acquire only that child; unselected full-size files are not downloaded.
Single-item Instagram posts retain the automatic Basic journey. Access is
logged-out and provider-dependent: challenges, incomplete metadata and unavailable
items are reported explicitly. See [Instagram scope and verification](docs/instagram/UPSTREAM.md).

The server renders normal HTML forms. JavaScript adds live updates, clipboard
handling, automatic desktop downloads, and the bounded iOS share action. The
form journey still works without JavaScript.

For X originals, JavaScript downloads with credentials omitted and no referrer.
It checks the media signature and transfer length, supports cancellation, and
refreshes an expired link once for the same item and resolution. There is no
silent server proxy. Browsers with a file picker can stream a manually requested
video to disk (up to 4 GiB). Other downloads and native file sharing prepare files up to 64 MiB. The existing
**Download** control opens larger originals directly in browsers without a file
picker. The existing multi-file ZIP action builds an uncompressed archive in the
browser, with the same 64 MiB aggregate preparation bound. Multi-photo sharing
remains available on iOS. Temporary result
pages expire independently of any CDN URL expiration.

## Runtime

```text
browser -> Caddy -> xvid -> X metadata
browser ----------------> X media CDN (original files)

Instagram and legacy conversions:
browser -> Caddy -> xvid -> media CDN -> FFprobe / optional FFmpeg
```

There is no generic extractor, Python service, Deno runtime, frontend framework,
Redis, account system, or permanent media library.

## Build and test

The Zig revision is pinned in `.zigversion`. Development requires SQLite 3.
The E2E journey and production also require FFmpeg/FFprobe with the MPEG-4,
H.264 (`libx264`), and AAC codecs available in the normal distribution package.
Missing tools fail the journey; real conversion is never skipped.

```bash
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
```

`zig build test` covers focused parsing, validation, state, and rendering logic.
`zig build e2e` launches the real xvid binary with deterministic Zig fixtures
and exercises the important HTTP, persistence, acquisition, conversion, Range,
cancellation, recovery, usage, and cleanup paths. A separate disposable instance
uses real tools to convert a generated one-second MPEG-4/AAC clip to H.264/AAC;
the HTTP-delivered file is probed for dimensions/pixel format/duration and decoded
in full. Synthetic fixtures remain for deliberate encoder failure and a stalled
encoder with a TERM-ignoring descendant. All upstream traffic is loopback fixture
traffic; these checks do not depend on live X availability.

For browser coverage, reuse an installed Playwright library and Chromium:

```bash
XVID_BROWSER_MODULE=/absolute/path/to/playwright-core/index.mjs \
XVID_BROWSER_SCREENSHOTS=/tmp/xvid-browser \
zig build e2e -Doptimize=ReleaseSafe
```

This also exercises the disposable server with JavaScript and native forms,
direct cross-origin downloads, expired-link refresh, cancellation, chunked responses,
size limits, file streaming, resolution selection, clipboard replacements/failures, edited
links, reload/history, and phone/desktop layouts. Clipboard permission responses
are simulated; actual iPhone paste prompts and sharing require a device check.

## Production

Verified pushes to `master` deploy automatically. A one-minute user-systemd
timer waits for the exact commit's GitHub `Verify` run to pass, then builds and
installs that revision on the VPS. It does not touch the development checkout.

For a manual verified deployment:

```bash
./scripts/vps_deploy.sh
```

The manual script runs the existing Zig checks before using the same install,
rollback, restart, and readiness path as automatic deployment.

Useful commands:

```bash
~/.local/lib/xvid/xvid version
~/.local/lib/xvid/xvid doctor --config ~/.config/xvid/config.json
~/.local/lib/xvid/xvid jobs --data ~/.local/share/xvid
~/.local/lib/xvid/xvid inspect --data ~/.local/share/xvid <job-id>
~/.local/lib/xvid/xvid prune --data ~/.local/share/xvid --dry-run
./scripts/check-x-upstream.sh
```

`inspect` omits submitted and provider transport URLs. Media expiry and manual
deletion do not remove the durable normalized usage rows.

Operational details are in [OPERATIONS.md](OPERATIONS.md). The unstable native-X
protocol provenance is recorded in [docs/x/UPSTREAM.md](docs/x/UPSTREAM.md).
