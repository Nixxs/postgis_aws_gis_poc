#!/usr/bin/env bash
set -euo pipefail

# Exercise inspection without a database; reject any mutation or source download.
export IMPORT_MODE=inspect SOURCE_URL=unused SOURCE_FILENAME=unused
export DB_HOST=unused DB_PORT=5432 DB_NAME=unused DB_USER=unused DB_PASSWORD=unused
export IMPORT_MANIFEST='{"layers":[{"target":"example_layer"}]}'
ogrinfo() {
  [[ "$1" == -ro && "$3" == *default_transaction_read_only=on* ]] || return 91
  [[ "$4" == -sql && "$5" == SELECT* ]] || return 92
  printf 'VERIFIED_READ_ONLY_SELECT\n'
}
curl() { echo 'Unexpected download' >&2; return 93; }
ogr2ogr() { echo 'Unexpected import' >&2; return 94; }
export -f ogrinfo curl ogr2ogr
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(bash "${root}/import.sh")"
[[ "$(grep -c VERIFIED_READ_ONLY_SELECT <<<"${output}")" == 4 ]]
[[ "${output}" == *'Read-only inspection complete.'* ]]
export IMPORT_MANIFEST='{"layers":[{"target":"bad; DROP TABLE x"}]}'
if bash "${root}/import.sh" >/dev/null 2>&1; then
  echo 'Invalid table identifier was accepted' >&2; exit 1
fi
echo 'PASS: read-only inspection uses only SELECT, never downloads/imports, and rejects invalid identifiers.'