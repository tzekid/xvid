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

required_commands=(awk cp curl flock git install mktemp mv rm seq sha256sum systemctl systemd-run zig)
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

wait_ready() {
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 2 http://127.0.0.1:8090/readyz >/dev/null 2>&1 && systemctl --user is-active --quiet xvid.service; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

verify_running() {
  local expected=$1
  for _ in $(seq 1 100); do
    main_pid=$(systemctl --user show xvid.service -p MainPID --value)
    if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
      running_hash=$(systemd-run --user --quiet --wait --collect --pipe \
        /usr/bin/sha256sum "/proc/$main_pid/exe" 2>/dev/null | awk '{print $1}' || true)
      [[ "$running_hash" == "$expected" ]] && return 0
    fi
    sleep 0.1
  done
  return 1
}

# Snapshot exactly the files this installer can replace, before promotion.
# Failed later controller/revision updates must roll back as well as readiness.
transaction=$(mktemp -d "$auto_state/transaction.XXXXXX")
managed_paths=("$binary_path" "$service_path" "$auto_path" "$auto_service_path"
  "$auto_timer_path" "$auto_state/deployed-revision" "$binary_path.previous" "$service_path.previous")
committed=false
promotion_started=false
service_active=false
service_enabled=false
timer_active=false
timer_enabled=false
systemctl --user is-active --quiet xvid.service && service_active=true
systemctl --user is-enabled --quiet xvid.service && service_enabled=true
systemctl --user is-active --quiet xvid-auto-deploy.timer && timer_active=true
systemctl --user is-enabled --quiet xvid-auto-deploy.timer && timer_enabled=true

finish_install() {
  local status=$? restore_failed=false index path
  trap - EXIT HUP INT TERM
  if ! $committed && $promotion_started; then
    printf 'candidate installation failed; restoring previous release\n' >&2
    systemctl --user stop xvid.service || restore_failed=true
    for index in "${!managed_paths[@]}"; do
      path=${managed_paths[$index]}
      if [[ -e "$transaction/$index" || -L "$transaction/$index" ]]; then
        if ! cp -a --remove-destination "$transaction/$index" "$path.new" || ! mv -f "$path.new" "$path"; then
          restore_failed=true
        fi
      else
        rm -f -- "$path" || restore_failed=true
      fi
      rm -f -- "$path.new" || restore_failed=true
    done
    systemctl --user daemon-reload || restore_failed=true
    if $service_enabled; then systemctl --user enable xvid.service >/dev/null || restore_failed=true
    else systemctl --user disable xvid.service >/dev/null || restore_failed=true; fi
    if $timer_enabled; then systemctl --user enable xvid-auto-deploy.timer >/dev/null || restore_failed=true
    else systemctl --user disable xvid-auto-deploy.timer >/dev/null || restore_failed=true; fi
    if $timer_active; then systemctl --user start xvid-auto-deploy.timer || restore_failed=true
    else systemctl --user stop xvid-auto-deploy.timer || restore_failed=true; fi
    if $service_active; then
      if [[ -f "$transaction/0" && -f "$transaction/1" ]]; then
        systemctl --user restart xvid.service || restore_failed=true
        wait_ready || restore_failed=true
        verify_running "$(sha256sum "$transaction/0" | awk '{print $1}')" || restore_failed=true
      else
        restore_failed=true
      fi
    fi
    status=1
  fi
  if $restore_failed; then
    printf 'rollback incomplete; retained recovery files: %s\n' "$transaction" >&2
    status=1
  else
    rm -rf -- "$transaction"
  fi
  exit "$status"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for index in "${!managed_paths[@]}"; do
  path=${managed_paths[$index]}
  if [[ -e "$path" || -L "$path" ]]; then cp -a -- "$path" "$transaction/$index"; fi
done

install -d -m 755 "$(dirname "$binary_path")" "$(dirname "$service_path")"
promotion_started=true
if [[ -f "$binary_path" ]]; then install -m 755 "$binary_path" "$binary_path.previous"; fi
if [[ -f "$service_path" ]]; then install -m 644 "$service_path" "$service_path.previous"; fi
install -m 755 zig-out/bin/xvid "$binary_path.new"
mv -f "$binary_path.new" "$binary_path"
install -m 644 deploy/xvid.service "$service_path.new"
mv -f "$service_path.new" "$service_path"

systemctl --user daemon-reload
systemctl --user enable xvid.service >/dev/null
systemctl --user restart xvid.service
wait_ready || die 'candidate readiness failed'
installed_hash=$(sha256sum "$binary_path" | awk '{print $1}')
main_pid=
running_hash=
verify_running "$installed_hash" || die 'running executable does not match the installed release'

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

committed=true

printf 'deployed %s\n' "$("$binary_path" version)"
printf 'source revision: %s\n' "$source_revision"
printf 'local readiness: ok\n'
printf 'running executable: %s (%s)\n' "$binary_path" "$running_hash"
printf 'automatic deployment timer: active\n'
