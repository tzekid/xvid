#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

required_commands=(git node zig)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

cd "$project_root"
git update-index -q --refresh
git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]] || die 'working tree must be clean'

node --check assets/app.js
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
zig fmt --check build.zig build.zig.zon src tests
git diff --check
exec "$project_root/scripts/vps_install.sh"
