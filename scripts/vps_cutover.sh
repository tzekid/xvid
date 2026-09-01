#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
site_file=${XVID_CADDY_SITES_FILE:-/etc/caddy/conf.d/sites.caddy}
root_file=${XVID_CADDY_ROOT_FILE:-/etc/caddy/Caddyfile}
replacement=$project_root/deploy/Caddyfile.xvid.plosca.ru

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

for command in awk caddy cp curl mktemp rg rm; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

curl -fsS --max-time 5 http://127.0.0.1:8090/readyz >/dev/null || die 'Zig readiness failed; refusing Caddy cutover'
rg -Fq 'request>uri regexp `\?.*$` ""' "$replacement" || die 'xvid Caddy block must redact complete query strings'
rg -Fq 'request>headers>Referer delete' "$replacement" || die 'xvid Caddy block must discard Referer headers'
[[ $(rg -c '^xvid\.plosca\.ru \{' "$site_file") == 1 ]] || die 'expected exactly one current xvid site block'
[[ $(rg -c '^api\.balancio\.plosca\.ru \{' "$site_file") == 1 ]] || die 'expected the verified post-xvid anchor'

candidate=$(mktemp "$site_file.xvid-next.XXXXXX")
backup=$(mktemp "$site_file.xvid-backup.XXXXXX")
cleanup() {
  [[ -e "$candidate" ]] && rm -f "$candidate"
}
trap cleanup EXIT
cp --preserve=mode,ownership,timestamps "$site_file" "$backup"

awk -v replacement="$replacement" '
  BEGIN {
    while ((getline line < replacement) > 0) replacement_text = replacement_text line "\n"
    close(replacement)
  }
  /^xvid\.plosca\.ru \{/ {
    printf "%s\n", replacement_text
    skipping = 1
    replaced = 1
    next
  }
  skipping && /^api\.balancio\.plosca\.ru \{/ { skipping = 0 }
  !skipping { print }
  END { if (!replaced || skipping) exit 42 }
' "$site_file" > "$candidate" || die 'could not construct bounded Caddy replacement'

cp --preserve=mode,ownership "$candidate" "$site_file"
if ! caddy adapt --config "$root_file" --adapter caddyfile >/dev/null || ! caddy reload --config "$root_file" --adapter caddyfile --force; then
  cp --preserve=mode,ownership "$backup" "$site_file"
  caddy reload --config "$root_file" --adapter caddyfile --force || true
  die "Caddy rejected the new configuration; restored $backup"
fi

curl -fsS --max-time 10 https://xvid.plosca.ru/readyz >/dev/null || {
  cp --preserve=mode,ownership "$backup" "$site_file"
  caddy reload --config "$root_file" --adapter caddyfile --force || true
  die "public readiness failed; restored $backup"
}

rm -f "$backup"
printf 'Caddy cutover complete: public readiness is healthy.\n'
