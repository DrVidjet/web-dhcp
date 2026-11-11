#!/bin/bash
# Пересобрать oui.tsv (производитель по MAC) из базы IEEE.
#   ./tools/make-oui.sh [oui.txt]   по умолчанию /usr/share/hwdata/oui.txt (пакет hwdata),
#                                   или скачать https://standards-oui.ieee.org/oui/oui.txt
# Формат oui.tsv: "XXXXXX<TAB>Название", строка на префикс.
set -euo pipefail
src=${1:-/usr/share/hwdata/oui.txt}
out=$(dirname "$0")/../oui.tsv
grep -E '^[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}[[:space:]]+\(hex\)' "$src" |
  sed -E 's/^([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})[[:space:]]+\(hex\)[[:space:]]+/\1\2\3\t/; s/\r$//' > "$out.tmp"
mv "$out.tmp" "$out"
echo "$out: $(wc -l < "$out") префиксов"
