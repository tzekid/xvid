#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
binary_path=${XVID_BINARY_PATH:-$HOME/.local/lib/xvid/xvid}
config_path=${XVID_CONFIG_PATH:-$HOME/.config/xvid/config.json}
service_path=${XVID_SERVICE_PATH:-$HOME/.config/systemd/user/xvid.service}
auto_path=${XVID_AUTO_DEPLOY_PATH:-$HOME/.local/lib/xvid/xvid-auto-deploy}
auto_service_path=${XVID_AUTO_DEPLOY_SERVICE_PATH:-$HOME/.config/systemd/user/xvid-auto-deploy.service}
auto_timer_path=${XVID_AUTO_DEPLOY_TIMER_PATH:-$HOME/.config/systemd/user/xvid-auto-deploy.timer}
auto_state=${XVID_AUTO_DEPLOY_STATE:-$HOME/.local/share/xvid-auto-deploy}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

required_commands=(awk curl flock git install mv seq sha256sum systemctl systemd-run zig)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

install -d -m 700 "$auto_state"
exec 9>"$auto_state/deploy.lock"
flock 9

cd "$project_root"
git update-index -q --refresh
git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]] || die 'working tree must be clean'
source_revision=$(git rev-parse HEAD)
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || die 'invalid source revision'
[[ -f "$config_path" ]] || die "missing production configuration: $config_path"

zig build -Doptimize=ReleaseSafe
./zig-out/bin/xvid doctor --config "$config_path"

install -d -m 755 "$(dirname "$binary_path")" "$(dirname "$service_path")"
install -d -m 700 "$HOME/.local/share/xvid"

if [[ -f "$binary_path" ]]; then
  install -m 755 "$binary_path" "$binary_path.previous"
fi
if [[ -f "$service_path" ]]; then
  install -m 644 "$service_path" "$service_path.previous"
fi

install -m 755 zig-out/bin/xvid "$binary_path.new"
mv -f "$binary_path.new" "$binary_path"
install -m 644 deploy/xvid.service "$service_path.new"
mv -f "$service_path.new" "$service_path"

wait_ready() {
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 2 http://127.0.0.1:8090/readyz >/dev/null 2>&1 && systemctl --user is-active --quiet xvid.service; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

systemctl --user daemon-reload
systemctl --user enable xvid.service >/dev/null
systemctl --user restart xvid.service

if ! wait_ready; then
  printf 'candidate readiness failed; restoring previous release\n' >&2
  if [[ ! -f "$binary_path.previous" || ! -f "$service_path.previous" ]]; then
    die 'candidate failed and no complete rollback pair exists'
  fi
  install -m 755 "$binary_path.previous" "$binary_path.new"
  mv -f "$binary_path.new" "$binary_path"
  install -m 644 "$service_path.previous" "$service_path.new"
  mv -f "$service_path.new" "$service_path"
  systemctl --user daemon-reload
  systemctl --user restart xvid.service
  wait_ready || die 'candidate and rollback release both failed readiness'
  die 'candidate failed readiness; previous release restored'
fi

installed_hash=$(sha256sum "$binary_path" | awk '{print $1}')
main_pid=
running_hash=
for _ in $(seq 1 100); do
  main_pid=$(systemctl --user show xvid.service -p MainPID --value)
  if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
    running_hash=$(systemd-run --user --quiet --wait --collect --pipe \
      /usr/bin/sha256sum "/proc/$main_pid/exe" 2>/dev/null | awk '{print $1}' || true)
    [[ "$running_hash" == "$installed_hash" ]] && break
  fi
  sleep 0.1
done
[[ "$running_hash" == "$installed_hash" ]] || die 'running executable does not match the installed release'

install -m 755 scripts/vps_auto_deploy.sh "$auto_path.new"
mv -f "$auto_path.new" "$auto_path"
install -m 644 deploy/xvid-auto-deploy.service "$auto_service_path.new"
mv -f "$auto_service_path.new" "$auto_service_path"
install -m 644 deploy/xvid-auto-deploy.timer "$auto_timer_path.new"
mv -f "$auto_timer_path.new" "$auto_timer_path"

printf '%s\n' "$source_revision" > "$auto_state/deployed-revision.new"
chmod 600 "$auto_state/deployed-revision.new"
mv -f "$auto_state/deployed-revision.new" "$auto_state/deployed-revision"

systemctl --user daemon-reload
systemctl --user enable --now xvid-auto-deploy.timer >/dev/null

printf 'deployed %s\n' "$("$binary_path" version)"
printf 'source revision: %s\n' "$source_revision"
printf 'local readiness: ok\n'
printf 'running executable: %s (%s)\n' "$binary_path" "$running_hash"
printf 'automatic deployment timer: active\n'
