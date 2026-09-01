# xvid

xvid is a small, mobile-first utility for saving photos and videos from public
X/Twitter status links.

Production is one Zig executable behind Caddy. It resolves X metadata natively,
downloads from the reviewed X media hosts, validates videos with FFprobe, and
uses FFmpeg only when the user asks for a compatible or smaller MP4. Jobs are
temporary filesystem directories; normalized usage records live in SQLite.

## User journeys

- **Basic:** paste a link, automatically download the best source media, then
  save or share it. There is no format-choice screen.
- **Advanced:** inspect the post, choose an available source quality, then keep
  the source or prepare a compatible/smaller MP4.

The server renders normal HTML forms. JavaScript adds live updates, clipboard
handling, automatic desktop downloads, and the bounded iOS share action. The
form journey still works without JavaScript.

## Runtime

```text
browser
  -> Caddy
  -> xvid
       -> X GraphQL, with syndication fallback
       -> pbs.twimg.com / video.twimg.com
       -> FFprobe
       -> optional FFmpeg
       -> temporary job files + usage.sqlite3
```

There is no generic extractor, Python service, Deno runtime, frontend framework,
Redis, account system, or permanent media library.

## Build and test

The Zig revision is pinned in `.zigversion`. Development requires SQLite 3;
production additionally requires FFmpeg and FFprobe.

```bash
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
```

`zig build test` covers focused parsing, validation, state, and rendering logic.
`zig build e2e` launches the real xvid binary with deterministic Zig fixtures
and exercises the important HTTP, persistence, acquisition, conversion, Range,
cancellation, recovery, usage, and cleanup paths.

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
