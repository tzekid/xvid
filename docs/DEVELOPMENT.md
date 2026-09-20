# Working on Xvid

The server is built and tested on Linux. Use the Zig version in
[`.zigversion`](../.zigversion), the SQLite development library, and FFmpeg/FFprobe.
The normal FFmpeg distribution should include MPEG-4, H.264 (`libx264`), and AAC.

## Run locally

From the repository root:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/xvid serve
```

Open [localhost:8090](http://127.0.0.1:8090). The default configuration stores
jobs in `./data` and keeps 2 GiB of disk space free. You can pass a JSON
configuration with `serve --config path/to/config.json`; the available settings
and defaults are in [`src/config.zig`](../src/config.zig).

## Check a change

```sh
node --check assets/app.js
zig fmt --check build.zig build.zig.zon src tests
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
```

The focused tests check the internal rules. The end-to-end suite starts the real
application with local providers and follows complete download journeys. It also
converts and decodes a generated video, so a passing result covers the delivered
file as well as the server’s response. These tests don’t depend on X or Instagram
being available, and missing media tools fail the run rather than skipping it.

The end-to-end suite also needs Bash, Python 3, SQLite’s command-line tool, curl,
ripgrep, and the standard Linux utilities used by [`tests/e2e.sh`](../tests/e2e.sh).
Python supports the test suite; it isn’t an application service.

### Include the browser

Reuse an installed Playwright library and Chromium:

```sh
XVID_BROWSER_MODULE=/absolute/path/to/playwright-core/index.mjs \
XVID_BROWSER_BIN=/usr/bin/chromium \
XVID_BROWSER_SCREENSHOTS=/tmp/xvid-browser \
zig build e2e -Doptimize=ReleaseSafe
```

This exercises the screens people actually use, including changing resolution,
repeating a download, pasting a different link, and saving several files. It also
checks that interrupted or expired transfers recover without quietly downloading
media through the server. Local fixture hosts stand in for the production CDNs,
so the browser test relaxes the content-security policy for those fixtures while
keeping cross-origin fetch rules active.

Clipboard responses and the iPhone share sheet are simulated. Confirm real paste
permissions and saving to Photos on a device when changing those behaviours.

## Where the work happens

For X originals, the server resolves metadata and sends the selected media links
to the browser. The browser fetches with credentials omitted and no referrer,
checks the file signature and transfer length, and refreshes an expired link once
for the same item and resolution. It never silently switches to a server proxy.
Multi-file ZIPs are assembled in the browser without recompressing their contents.

Instagram downloads and older clients that explicitly request video conversion
still use the server’s media path. Existing conversion support is kept out of the
normal interface, where choosing a resolution always keeps that source file.

The server renders usable forms without JavaScript. JavaScript adds the clipboard,
live progress, direct X file preparation, ZIPs, and sharing. Without it, individual
X originals remain available as direct links; the browser handles opening or
saving them.

Job directories are temporary. SQLite keeps normalized usage records separately,
so expiring a download doesn’t erase the usage history. A direct X job becomes
`ready` when its metadata is resolved; that does not mean a user has saved the file.

## Deploy and diagnose

Successful pushes to `master` deploy automatically. For a manual release from a
clean checkout, use:

```sh
./scripts/vps_deploy.sh
```

The script runs the checks before installing the executable, and restores the
previous release if readiness fails. See [OPERATIONS.md](../OPERATIONS.md) for
the service layout, configuration, backups, and rollback details.

These commands help inspect a hosted installation:

```sh
~/.local/lib/xvid/xvid version
~/.local/lib/xvid/xvid doctor --config ~/.config/xvid/config.json
~/.local/lib/xvid/xvid jobs --data ~/.local/share/xvid
~/.local/lib/xvid/xvid inspect --data ~/.local/share/xvid <job-id>
~/.local/lib/xvid/xvid prune --data ~/.local/share/xvid --dry-run
./scripts/check-x-upstream.sh
```

`inspect` leaves out submitted links and provider media URLs. Keep those URLs,
tokens, cookies, and provider response bodies out of logs and commits.

The same E2E target also fills the HTTP pool with incomplete/trickled requests,
checks TERM with SSE, blocked metadata and an encoder descendant, and restarts
the same disposable data to verify recovery. Installer scenarios use temporary
files and explicit command failures to prove restart, readiness, hash and later
controller-update rollback plus deployment-lock serialization. They never
operate on the real service or data directory.
