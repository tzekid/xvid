#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin"

repository=tzekid/xvid
branch=master
repository_url=https://github.com/tzekid/xvid.git
state_root=$HOME/.local/share/xvid-auto-deploy
revision_file=$state_root/deployed-revision
failed_file=$state_root/failed-revision

required_commands=(awk curl find flock git install jq mktemp tr)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'auto_deploy_error=missing_command command=%s\n' "$command" >&2
    exit 1
  }
done

install -d -m 700 "$state_root"
exec 9>"$state_root/watch.lock"
flock -n 9 || exit 0

remote_sha=$(git ls-remote "$repository_url" "refs/heads/$branch" | awk 'NR == 1 {print $1}')
[[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'auto_deploy_error=invalid_remote_revision\n' >&2
  exit 1
}

deployed_sha=
if [[ -f "$revision_file" ]]; then
  deployed_sha=$(tr -d '\r\n' < "$revision_file")
fi
[[ "$deployed_sha" == "$remote_sha" ]] && exit 0

failed_sha=
if [[ -f "$failed_file" ]]; then
  failed_sha=$(tr -d '\r\n' < "$failed_file")
fi
[[ "$failed_sha" == "$remote_sha" ]] && exit 0

run_file=$(mktemp "$state_root/run.XXXXXX")
release_root=
cleanup() {
  find "$run_file" -delete 2>/dev/null || true
  if [[ -n "$release_root" ]]; then
    find "$release_root" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

curl --fail --silent --show-error --retry 2 --get \
  -H 'Accept: application/vnd.github+json' \
  --data-urlencode "head_sha=$remote_sha" \
  --data-urlencode 'event=push' \
  --data-urlencode "branch=$branch" \
  --data-urlencode 'per_page=10' \
  "https://api.github.com/repos/$repository/actions/runs" > "$run_file"

run_state=$(jq -r --arg sha "$remote_sha" '
  [.workflow_runs[] |
    select(.name == "Verify" and .event == "push" and .head_branch == "master" and .head_sha == $sha)] |
  sort_by(.run_number) |
  last |
  if . == null then "missing" else (.status + ":" + (.conclusion // "")) end
' "$run_file")

[[ "$run_state" == completed:success ]] || exit 0

release_root=$(mktemp -d "$state_root/release.XXXXXX")
git clone --quiet --depth 1 --branch "$branch" "$repository_url" "$release_root/repo"
release_sha=$(git -C "$release_root/repo" rev-parse HEAD)
[[ "$release_sha" == "$remote_sha" ]] || exit 0

latest_sha=$(git ls-remote "$repository_url" "refs/heads/$branch" | awk 'NR == 1 {print $1}')
[[ "$latest_sha" == "$remote_sha" ]] || exit 0

printf 'auto_deploy_start revision=%s\n' "$remote_sha"
if "$release_root/repo/scripts/vps_install.sh"; then
  find "$failed_file" -delete 2>/dev/null || true
  printf 'auto_deploy_complete revision=%s\n' "$remote_sha"
else
  printf '%s\n' "$remote_sha" > "$failed_file.new"
  chmod 600 "$failed_file.new"
  mv -f "$failed_file.new" "$failed_file"
  printf 'auto_deploy_failed revision=%s\n' "$remote_sha" >&2
  exit 1
fi
