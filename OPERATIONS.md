# Operations

## Production layout

```text
~/.local/lib/xvid/xvid
~/.local/lib/xvid/xvid.previous
~/.config/xvid/config.json
~/.config/systemd/user/xvid.service
~/.local/share/xvid/jobs/
~/.local/share/xvid/usage.sqlite3
```

Caddy proxies `https://xvid.plosca.ru` to `127.0.0.1:8090`. The systemd user
service owns the data directory. Configuration is strict, so a binary and a
configuration schema change are deployed together.

## Deploy

Every successful `Verify` run for a push to `master` is deployed automatically.
`xvid-auto-deploy.timer` checks once a minute, clones the exact current revision
into a private temporary directory, builds it on the VPS, and uses the normal
rollback/readiness path. Pending, failed, and stale revisions are not deployed.

Status and logs:

```bash
systemctl --user status xvid-auto-deploy.timer
journalctl --user -u xvid-auto-deploy.service
```

A release that fails installation is recorded in
`~/.local/share/xvid-auto-deploy/failed-revision` and is not retried forever.
Remove that file and start `xvid-auto-deploy.service` only when intentionally
retrying the same revision.

For a manual deployment from a clean `master` checkout:

```bash
./scripts/vps_deploy.sh
```

The script runs the focused Zig tests and real-process E2E journey before calling
the same installer used by automatic deployment. The installer builds the
ReleaseSafe executable, checks the production configuration, preserves the old
binary and service unit, restarts the service, waits for local readiness, and
checks that `/proc/<MainPID>/exe` matches the installed file. A readiness failure
restores the previous binary and unit automatically.

After deployment, the shortest useful operator check is:

```bash
curl -fsS https://xvid.plosca.ru/readyz
systemctl --user show xvid.service -p ActiveState -p MainPID -p NRestarts
```

For a user-facing change, exercise the affected public journey once and remove
the temporary job afterward.

## Common commands

```bash
systemctl --user restart xvid.service
journalctl --user -u xvid.service -f
~/.local/lib/xvid/xvid doctor --config ~/.config/xvid/config.json
~/.local/lib/xvid/xvid jobs --data ~/.local/share/xvid
~/.local/lib/xvid/xvid inspect --data ~/.local/share/xvid <job-id>
~/.local/lib/xvid/xvid prune --data ~/.local/share/xvid --dry-run
```

Mutating prune is offline maintenance and refuses to run while the service owns
the data directory.

## Usage database

Temporary media and manifests expire independently of the normalized usage
ledger. Back up the database through SQLite rather than copying WAL files:

```bash
sqlite3 ~/.local/share/xvid/usage.sqlite3 \
  ".backup '$HOME/.local/share/xvid/usage.backup.sqlite3'"
```

## Rollback

`scripts/vps_deploy.sh` retains the previously installed executable. If a
release must be rolled back, restore `xvid.previous` together with the matching
configuration when the schema changed, restart the service, and verify local
and public readiness.

## X changes

X's metadata interface is undocumented. The weekly upstream workflow compares
the reviewed yt-dlp Twitter extractor blob and opens one issue when it changes.
It does not modify or deploy xvid. See [docs/x/UPSTREAM.md](docs/x/UPSTREAM.md)
and run `./scripts/check-x-upstream.sh` manually when investigating drift.

`scripts/vps_cutover.sh` is only for initially installing or repairing the Caddy
site block; routine releases use `scripts/vps_deploy.sh`.
