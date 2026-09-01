#!/usr/bin/env bash
set -euo pipefail

for required_command in curl jq mktemp; do
  command -v "$required_command" >/dev/null 2>&1 || {
    printf 'missing command: %s\n' "$required_command" >&2
    exit 1
  }
done

watch_temp=$(mktemp -d)
cleanup_watch() {
  find "$watch_temp" -depth -delete 2>/dev/null || true
}
trap cleanup_watch EXIT

api_headers=(
  -H 'Accept: application/vnd.github+json'
  -H 'X-GitHub-Api-Version: 2026-03-10'
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  api_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

api_get() {
  curl --fail --silent --show-error --location --retry 2 --retry-delay 1 \
    "${api_headers[@]}" "$@"
}

check_source() {
  local key=$1
  local repository=$2
  local path=$3
  local reviewed_commit=$4
  local reviewed_blob=$5
  local content_file="$watch_temp/$key-content.json"
  local commits_file="$watch_temp/$key-commits.json"

  api_get "https://api.github.com/repos/$repository/contents/$path" > "$content_file"
  api_get --get \
    --data-urlencode "path=$path" \
    --data-urlencode 'per_page=1' \
    "https://api.github.com/repos/$repository/commits" > "$commits_file"

  local current_blob
  local current_commit
  current_blob=$(jq -er 'select(.type == "file") | .sha | select(test("^[0-9a-f]{40}$"))' "$content_file")
  current_commit=$(jq -er '.[0].sha | select(test("^[0-9a-f]{40}$"))' "$commits_file")

  jq -n \
    --arg key "$key" \
    --arg repository "$repository" \
    --arg path "$path" \
    --arg reviewed_commit "$reviewed_commit" \
    --arg reviewed_blob "$reviewed_blob" \
    --arg current_commit "$current_commit" \
    --arg current_blob "$current_blob" \
    --arg diff_url "https://github.com/$repository/compare/$reviewed_commit...$current_commit" \
    '{
      key: $key,
      repository: $repository,
      path: $path,
      reviewed_commit: $reviewed_commit,
      reviewed_blob: $reviewed_blob,
      current_commit: $current_commit,
      current_blob: $current_blob,
      changed: ($reviewed_blob != $current_blob),
      diff_url: $diff_url
    }'
}

check_source \
  yt_dlp \
  yt-dlp/yt-dlp \
  yt_dlp/extractor/twitter.py \
  2bbfb9972c8f514740a5fcfdff38374d08e9c15c \
  ebac006e5a69a13ce55ddd24d4a47226420a932f \
  > "$watch_temp/yt-dlp.json"

jq -s '{
  schema: 1,
  checked_at: (now | todateiso8601),
  changed: any(.[]; .changed),
  sources: .
}' "$watch_temp/yt-dlp.json"
