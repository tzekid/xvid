#!/usr/bin/env bash
set -euo pipefail

xvid_bin=$(realpath "$1")
fixture_ffmpeg=$(realpath "$2")
fixture_ffprobe=$(realpath "$3")
fixture_x_server=$(realpath "$4")
xvid_temp=$(mktemp -d)
xvid_pid=""
x_server_pid=""
current_stage="bootstrap"

stage() {
  current_stage=$1
  printf 'E2E: %s\n' "$current_stage"
}

cleanup() {
  if [[ -n "$xvid_pid" ]] && kill -0 "$xvid_pid" 2>/dev/null; then
    kill -KILL "$xvid_pid" 2>/dev/null || true
    wait "$xvid_pid" 2>/dev/null || true
  fi
  if [[ -n "$x_server_pid" ]] && kill -0 "$x_server_pid" 2>/dev/null; then
    kill -KILL "$x_server_pid" 2>/dev/null || true
    wait "$x_server_pid" 2>/dev/null || true
  fi
  while IFS= read -r pid_file; do
    fixture_pid=$(tr -dc '0-9' < "$pid_file")
    if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
      kill -KILL "$fixture_pid" 2>/dev/null || true
    fi
  done < <(find "$xvid_temp" -type f -name ffmpeg-descendant.pid 2>/dev/null)
  find "$xvid_temp" -depth -delete 2>/dev/null || true
}

diagnose() {
  local status=$1
  local line=$2
  local command=$3
  trap - ERR
  set +e
  printf '\nE2E FAILED status=%s stage=%s line=%s command=%s\n' "$status" "$current_stage" "$line" "$command" >&2
  if [[ -f "$xvid_temp/server.log" ]]; then
    printf '%s\n' '--- server.log ---' >&2
    tail -n 300 "$xvid_temp/server.log" >&2
  fi
  if [[ -f "$xvid_temp/x-server.log" ]]; then
    printf '%s\n' '--- x-server.log ---' >&2
    tail -n 160 "$xvid_temp/x-server.log" >&2
  fi
  if [[ -d "$xvid_temp/data/jobs" ]]; then
    printf '%s\n' '--- retained job manifests ---' >&2
    while IFS= read -r manifest_path; do
      printf '%s\n' "--- $manifest_path ---" >&2
      cat "$manifest_path" >&2
    done < <(find "$xvid_temp/data/jobs" -name job.json -type f | sort)
    printf '%s\n' '--- retained files ---' >&2
    find "$xvid_temp/data/jobs" -maxdepth 4 -type f -printf '%p %s bytes\n' >&2
  fi
  printf '%s\n' '--- generated HTTP captures ---' >&2
  find "$xvid_temp" -maxdepth 1 -type f \( -name '*.headers' -o -name '*.html' -o -name '*.txt' \) -print -exec sh -c 'printf "--- %s ---\n" "$1"; tail -n 80 "$1"' _ {} \; >&2
  exit "$status"
}

trap 'diagnose "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

for command in curl find grep python3 realpath rg sed seq sqlite3 tr unzip; do
  command -v "$command" >/dev/null
done

xvid_port=$((22000 + $$ % 18000))
x_server_port=$((xvid_port + 1))
xvid_origin="http://127.0.0.1:$xvid_port"
x_origin="http://127.0.0.1:$x_server_port"
xvid_config="$xvid_temp/config.json"

cat > "$xvid_config" <<JSON
{
  "listen": "127.0.0.1:$xvid_port",
  "public_origin": "$xvid_origin",
  "data_dir": "$xvid_temp/data",
  "http_workers": 16,
  "http_queue": 32,
  "http_inactivity_seconds": 30,
  "max_open_sse": 4,
  "max_artifact_streams": 8,
  "max_loaded_jobs": 32,
  "rate_limit_capacity": 32,
  "probes_per_minute": 100,
  "jobs_per_hour": 100,
  "choice_ttl_seconds": 60,
  "terminal_ttl_seconds": 60,
  "cleanup_interval_seconds": 1,
  "quarantine_ttl_seconds": 3600,
  "probe_workers": 2,
  "max_queued_probes": 8,
  "media_workers": 1,
  "max_queued_media": 8,
  "download_timeout_seconds": 60,
  "download_inactivity_seconds": 10,
  "ffprobe_timeout_seconds": 10,
  "encode_timeout_seconds": 60,
  "encode_inactivity_seconds": 10,
  "ffmpeg_threads": 2,
  "max_download_bytes": 8388608,
  "max_output_bytes": 8388608,
  "job_storage_budget_bytes": 33554432,
  "minimum_free_bytes": 1048576,
  "max_media_duration_seconds": 60,
  "ffmpeg": "$fixture_ffmpeg",
  "ffprobe": "$fixture_ffprobe",
  "x_guest_endpoint": "$x_origin/guest",
  "x_graphql_endpoint": "$x_origin/graphql",
  "x_syndication_endpoint": "$x_origin/tweet-result",
  "x_metadata_timeout_seconds": 10,
  "x_photo_media_hosts": ["127.0.0.1"],
  "x_video_media_hosts": ["127.0.0.1"]
}
JSON

"$fixture_x_server" "127.0.0.1:$x_server_port" >>"$xvid_temp/x-server.log" 2>&1 &
x_server_pid=$!
for _ in $(seq 1 200); do
  curl -fsS "$x_origin/ready" >/dev/null 2>&1 && break
  sleep 0.025
done
curl -fsS "$x_origin/ready" >/dev/null

start_server() {
  "$xvid_bin" serve --config "$xvid_config" >>"$xvid_temp/server.log" 2>&1 &
  xvid_pid=$!
  for _ in $(seq 1 300); do
    curl -fsS "$xvid_origin/readyz" >/dev/null 2>&1 && return
    sleep 0.025
  done
  return 1
}

stop_server() {
  local signal=${1:-TERM}
  kill -"$signal" "$xvid_pid"
  wait "$xvid_pid" 2>/dev/null || true
  xvid_pid=""
}

create_job() {
  local source_url=$1
  local advanced=${2:-0}
  local headers=$3
  local arguments=(
    -sS -D "$headers" -o /dev/null -X POST
    -H 'Content-Type: application/x-www-form-urlencoded'
    --data-urlencode "url=$source_url"
  )
  if [[ "$advanced" == 1 ]]; then arguments+=(--data 'advanced=1'); fi
  curl "${arguments[@]}" "$xvid_origin/jobs"
  awk 'BEGIN{IGNORECASE=1} /^location:/{gsub("\r",""); print $2}' "$headers"
}

job_path_from_location() {
  local location=${1%%\?*}
  printf '%s' "$location"
}

job_id_from_location() {
  local path
  path=$(job_path_from_location "$1")
  printf '%s' "${path##*/}"
}

wait_for_state() {
  local manifest=$1
  local wanted=$2
  local attempts=${3:-600}
  for _ in $(seq 1 "$attempts"); do
    if rg -q "\"state\": \"$wanted\"" "$manifest" 2>/dev/null; then return; fi
    sleep 0.025
  done
  printf 'state %s not reached in %s\n' "$wanted" "$manifest" >&2
  [[ -f "$manifest" ]] && cat "$manifest" >&2
  return 1
}

wait_for_absence() {
  local path=$1
  local attempts=${2:-400}
  for _ in $(seq 1 "$attempts"); do
    [[ ! -e "$path" ]] && return
    sleep 0.025
  done
  printf 'path still exists: %s\n' "$path" >&2
  return 1
}

post_job_action() {
  local path=$1
  local action=$2
  local body=${3:-}
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data "$body" "$xvid_origin$path/$action"
}

delete_job() {
  local path=$1
  post_job_action "$path" delete || true
}

assert_status() {
  local expected=$1
  shift
  local actual
  actual=$(curl -sS -o "$xvid_temp/status-body.html" -w '%{http_code}' "$@")
  [[ "$actual" == "$expected" ]] || {
    printf 'expected HTTP %s, got %s\n' "$expected" "$actual" >&2
    cat "$xvid_temp/status-body.html" >&2
    return 1
  }
}

stage 'start fixture and application'
start_server
usage_db="$xvid_temp/data/usage.sqlite3"
[[ -f "$usage_db" ]]
[[ "$(sqlite3 "$usage_db" 'PRAGMA quick_check')" == ok ]]
[[ "$(sqlite3 "$usage_db" 'PRAGMA user_version')" == 1 ]]
[[ "$(sqlite3 "$usage_db" "SELECT count(*) FROM pragma_table_info('usage_jobs') WHERE name IN ('source_url','title')")" == 0 ]]

stage 'home and native-only boundary'
curl -fsS "$xvid_origin/" > "$xvid_temp/home.html"
rg -q '<main id="app"' "$xvid_temp/home.html"
rg -q 'Save media from an X link' "$xvid_temp/home.html"
rg -q 'data-basic-submit' "$xvid_temp/home.html"
rg -q 'name="advanced" value="1" data-advanced-submit' "$xvid_temp/home.html"
rg -q '/assets/app\.js\?v=3' "$xvid_temp/home.html"
! rg -qi 'yt-dlp|youtube|vimeo|generic provider' "$xvid_temp/home.html"

stage 'cross-site mutation rejection'
assert_status 403 -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Sec-Fetch-Site: cross-site' \
  -H 'Origin: https://evil.example' \
  --data-urlencode 'url=https://x.com/fixture/status/2103' \
  "$xvid_origin/jobs"
rg -q 'Request blocked' "$xvid_temp/status-body.html"
[[ "$(find "$xvid_temp/data/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 0 ]]

stage 'non-X rejection'
assert_status 422 -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'url=https://example.com/video.mp4' \
  "$xvid_origin/jobs"
rg -q 'currently accepts public X and Twitter status links only' "$xvid_temp/status-body.html"

stage 'Basic native Original journey'
basic_location=$(create_job 'https://x.com/fixture/status/2103' 0 "$xvid_temp/basic.headers")
[[ "$basic_location" == *'?auto=1' ]]
basic_path=$(job_path_from_location "$basic_location")
basic_id=$(job_id_from_location "$basic_location")
basic_manifest="$xvid_temp/data/jobs/$basic_id/job.json"
wait_for_state "$basic_manifest" ready
rg -q '"intent": "save_original"' "$basic_manifest"
rg -q '"engine": "x_native"' "$basic_manifest"
rg -q '"mode": "original"' "$basic_manifest"
rg -q '"path": "preview/item-001.png"' "$basic_manifest"
[[ ! -e "$xvid_temp/data/jobs/$basic_id/.fixture-ffmpeg-invoked" ]]
[[ "$(find "$xvid_temp/data/jobs/$basic_id/preview" -type f | wc -l)" == 1 ]]

curl -fsS "$xvid_origin$basic_location" > "$xvid_temp/basic.html"
rg -q 'Ready to save' "$xvid_temp/basic.html"
rg -q 'data-auto-download' "$xvid_temp/basic.html"
rg -Fq "poster=\"$basic_path/artifact/file-1?poster=1\"" "$xvid_temp/basic.html"
if rg -q 'data-events=' "$xvid_temp/basic.html"; then
  printf 'ready page unexpectedly retained an event stream\n' >&2
  false
fi
! rg -q "$x_origin" "$xvid_temp/basic.html"

curl -fsS -D "$xvid_temp/basic-poster.headers" "$xvid_origin$basic_path/artifact/file-1?poster=1" > "$xvid_temp/basic-poster.png"
rg -qi '^content-type: image/png' "$xvid_temp/basic-poster.headers"
! rg -qi '^content-disposition:' "$xvid_temp/basic-poster.headers"
rg -a -q 'PNG' "$xvid_temp/basic-poster.png"
[[ "$(sqlite3 "$usage_db" "SELECT count(*) FROM usage_deliveries WHERE job_id='$basic_id'")" == 0 ]]

curl -fsSI "$xvid_origin$basic_path/artifact/file-1" > "$xvid_temp/basic-head.txt"
rg -qi '^accept-ranges: bytes' "$xvid_temp/basic-head.txt"
curl -fsS -H 'Range: bytes=0-7' -D "$xvid_temp/basic-range.headers" "$xvid_origin$basic_path/artifact/file-1" > "$xvid_temp/basic-range.bin"
rg -q '206' "$xvid_temp/basic-range.headers"
[[ "$(wc -c < "$xvid_temp/basic-range.bin")" == 8 ]]
curl -fsS "$xvid_origin$basic_path/artifact/file-1?download=1" > "$xvid_temp/basic.mp4"
rg -a -q 'ftyp' "$xvid_temp/basic.mp4"
[[ "$(sqlite3 "$usage_db" "SELECT count(*) FROM usage_deliveries WHERE job_id='$basic_id' AND kind='download_response_complete'")" == 1 ]]
delete_job "$basic_path"
wait_for_absence "$xvid_temp/data/jobs/$basic_id"

stage 'invalid optional poster keeps the video usable'
posterless_location=$(create_job 'https://x.com/fixture/status/2140' 0 "$xvid_temp/posterless.headers")
posterless_path=$(job_path_from_location "$posterless_location")
posterless_id=$(job_id_from_location "$posterless_location")
posterless_manifest="$xvid_temp/data/jobs/$posterless_id/job.json"
wait_for_state "$posterless_manifest" ready
rg -q '"poster": null' "$posterless_manifest"
[[ -z "$(find "$xvid_temp/data/jobs/$posterless_id/preview" -type f -print -quit)" ]]
curl -fsS "$xvid_origin$posterless_path" > "$xvid_temp/posterless.html"
! rg -q '<video[^>]+ poster=' "$xvid_temp/posterless.html"
curl -fsS "$xvid_origin$posterless_path/artifact/file-1" > "$xvid_temp/posterless.mp4"
rg -a -q 'ftyp' "$xvid_temp/posterless.mp4"
delete_job "$posterless_path"
wait_for_absence "$xvid_temp/data/jobs/$posterless_id"

stage 'Advanced lower source quality journey'
advanced_location=$(create_job 'https://x.com/fixture/status/2103' 1 "$xvid_temp/advanced.headers")
advanced_path=$(job_path_from_location "$advanced_location")
advanced_id=$(job_id_from_location "$advanced_location")
advanced_manifest="$xvid_temp/data/jobs/$advanced_id/job.json"
wait_for_state "$advanced_manifest" awaiting_choice
curl -fsS "$xvid_origin$advanced_path" > "$xvid_temp/advanced.html"
rg -q 'Choose what to save' "$xvid_temp/advanced.html"
rg -q 'Compatible MP4' "$xvid_temp/advanced.html"
rg -q 'Smaller MP4' "$xvid_temp/advanced.html"
rg -q 'value="video-720"' "$xvid_temp/advanced.html"
rg -q 'value="480" data-target-height="480"' "$xvid_temp/advanced.html"
post_job_action "$advanced_path" start 'kind=video&variant=video-720&delivery=original'
wait_for_state "$advanced_manifest" ready
rg -q '"variant_id": "video-720"' "$advanced_manifest"
rg -a -q 'height=720' "$xvid_temp/data/jobs/$advanced_id/source/item-001.mp4"
[[ ! -e "$xvid_temp/data/jobs/$advanced_id/.fixture-ffmpeg-invoked" ]]
delete_job "$advanced_path"
wait_for_absence "$xvid_temp/data/jobs/$advanced_id"

stage 'Compatible MP4 journey'
convert_location=$(create_job 'https://x.com/fixture/status/2103' 1 "$xvid_temp/convert.headers")
convert_path=$(job_path_from_location "$convert_location")
convert_id=$(job_id_from_location "$convert_location")
convert_manifest="$xvid_temp/data/jobs/$convert_id/job.json"
wait_for_state "$convert_manifest" awaiting_choice
post_job_action "$convert_path" start 'kind=video&variant=best&delivery=optimise'
wait_for_state "$convert_manifest" ready
[[ -e "$xvid_temp/data/jobs/$convert_id/.fixture-ffmpeg-invoked" ]]
rg -q '"mode": "optimise"' "$convert_manifest"
rg -q '"path": "output/item-001.mp4"' "$convert_manifest"
rg -q '"path": "preview/item-001.png"' "$convert_manifest"
rg -a -q 'fixture-output height=1080' "$xvid_temp/data/jobs/$convert_id/output/item-001.mp4"
curl -fsS "$xvid_origin$convert_path" > "$xvid_temp/convert.html"
rg -Fq "poster=\"$convert_path/artifact/output-1?poster=1\"" "$xvid_temp/convert.html"
curl -fsS "$xvid_origin$convert_path/artifact/output-1?poster=1" > "$xvid_temp/convert-poster.png"
cmp "$xvid_temp/basic-poster.png" "$xvid_temp/convert-poster.png"
delete_job "$convert_path"
wait_for_absence "$xvid_temp/data/jobs/$convert_id"

stage 'Smaller MP4 journey'
downscale_location=$(create_job 'https://x.com/fixture/status/2103' 1 "$xvid_temp/downscale.headers")
downscale_path=$(job_path_from_location "$downscale_location")
downscale_id=$(job_id_from_location "$downscale_location")
downscale_manifest="$xvid_temp/data/jobs/$downscale_id/job.json"
wait_for_state "$downscale_manifest" awaiting_choice
post_job_action "$downscale_path" start 'kind=video&variant=best&delivery=downscale&target_height=720'
wait_for_state "$downscale_manifest" ready
rg -q '"target_height": 720' "$downscale_manifest"
rg -a -q 'fixture-output height=720' "$xvid_temp/data/jobs/$downscale_id/output/item-001.mp4"
delete_job "$downscale_path"
wait_for_absence "$xvid_temp/data/jobs/$downscale_id"

stage 'multi-photo ZIP journey'
photos_location=$(create_job 'https://x.com/fixture/status/2102' 0 "$xvid_temp/photos.headers")
photos_path=$(job_path_from_location "$photos_location")
photos_id=$(job_id_from_location "$photos_location")
photos_manifest="$xvid_temp/data/jobs/$photos_id/job.json"
wait_for_state "$photos_manifest" ready
[[ "$(find "$xvid_temp/data/jobs/$photos_id/source" -type f | wc -l)" == 4 ]]
[[ -f "$xvid_temp/data/jobs/$photos_id/output/bundle.zip" ]]
unzip -t "$xvid_temp/data/jobs/$photos_id/output/bundle.zip" >/dev/null
curl -fsS "$xvid_origin$photos_path" > "$xvid_temp/photos.html"
rg -Fq 'Download all (.zip)' "$xvid_temp/photos.html"
rg -q 'data-share-photos hidden' "$xvid_temp/photos.html"
delete_job "$photos_path"
wait_for_absence "$xvid_temp/data/jobs/$photos_id"

stage 'specific private-post failure'
private_location=$(create_job 'https://x.com/fixture/status/2112' 1 "$xvid_temp/private.headers")
private_path=$(job_path_from_location "$private_location")
private_id=$(job_id_from_location "$private_location")
private_manifest="$xvid_temp/data/jobs/$private_id/job.json"
wait_for_state "$private_manifest" failed
rg -q '"code": "X_PRIVATE"' "$private_manifest"
curl -fsS "$xvid_origin$private_path" > "$xvid_temp/private.html"
rg -q 'This media is not public' "$xvid_temp/private.html"
delete_job "$private_path"
wait_for_absence "$xvid_temp/data/jobs/$private_id"

stage 'probe cancellation'
cancel_location=$(create_job 'https://x.com/fixture/status/2135' 1 "$xvid_temp/cancel.headers")
cancel_path=$(job_path_from_location "$cancel_location")
cancel_id=$(job_id_from_location "$cancel_location")
cancel_manifest="$xvid_temp/data/jobs/$cancel_id/job.json"
post_job_action "$cancel_path" cancel
wait_for_state "$cancel_manifest" cancelled
sleep 2.5
rg -q '"state": "cancelled"' "$cancel_manifest"
[[ -z "$(find "$xvid_temp/data/jobs/$cancel_id/source" "$xvid_temp/data/jobs/$cancel_id/output" -type f -print -quit)" ]]
delete_job "$cancel_path"
wait_for_absence "$xvid_temp/data/jobs/$cancel_id"

stage 'crash recovery during native acquisition'
recovery_location=$(create_job 'https://x.com/fixture/status/2130' 0 "$xvid_temp/recovery.headers")
recovery_path=$(job_path_from_location "$recovery_location")
recovery_id=$(job_id_from_location "$recovery_location")
recovery_manifest="$xvid_temp/data/jobs/$recovery_id/job.json"
wait_for_state "$recovery_manifest" acquiring
stop_server KILL
start_server
wait_for_state "$recovery_manifest" ready 1200
[[ -f "$xvid_temp/data/jobs/$recovery_id/source/item-001.jpg" ]]
delete_job "$recovery_path"
wait_for_absence "$xvid_temp/data/jobs/$recovery_id"

stage 'abandoned Advanced choice expiry across restart'
expiry_location=$(create_job 'https://x.com/fixture/status/2101' 1 "$xvid_temp/expiry.headers")
expiry_path=$(job_path_from_location "$expiry_location")
expiry_id=$(job_id_from_location "$expiry_location")
expiry_manifest="$xvid_temp/data/jobs/$expiry_id/job.json"
wait_for_state "$expiry_manifest" awaiting_choice
stop_server TERM
sed -E -i '0,/"created_at": [0-9]+/s//"created_at": 1/' "$expiry_manifest"
sed -E -i '0,/"updated_at": [0-9]+/s//"updated_at": 1/' "$expiry_manifest"
start_server
wait_for_absence "$xvid_temp/data/jobs/$expiry_id" 800

stage 'SSE revisions and terminal event'
sse_location=$(create_job 'https://x.com/fixture/status/2103' 0 "$xvid_temp/sse.headers")
sse_path=$(job_path_from_location "$sse_location")
sse_id=$(job_id_from_location "$sse_location")
sse_manifest="$xvid_temp/data/jobs/$sse_id/job.json"
curl -sN --max-time 8 "$xvid_origin$sse_path/events" > "$xvid_temp/events.txt" || true
wait_for_state "$sse_manifest" ready
rg -q '^event: job' "$xvid_temp/events.txt"
rg -q '^id: [0-9]+' "$xvid_temp/events.txt"
rg -q '^event: done' "$xvid_temp/events.txt"
delete_job "$sse_path"
wait_for_absence "$xvid_temp/data/jobs/$sse_id"

stage 'final privacy, disk, and ledger checks'
! rg -qi 'yt-dlp|ytdlp|youtube|vimeo' "$xvid_temp/server.log"
[[ "$(find "$xvid_temp/data/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 0 ]]
[[ -z "$(find "$xvid_temp/data/jobs" -type f \( -name '*.part' -o -name '*.tmp' \) -print -quit)" ]]
[[ "$(sqlite3 "$usage_db" 'PRAGMA quick_check')" == ok ]]

printf 'native-X end-to-end journeys: pass\n'
