#!/usr/bin/env bash
# lib/health-check.sh
#
# Post-bootstrap verification: probes every service in services.json
# and every model in models.json, prints a status table, exits 1 if
# anything is down. Any HTTP answer counts as UP (an auth-gated 401 is
# a living service); only connection failure or timeout is DOWN.
#
#   bash lib/health-check.sh

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

printf '%-22s %-8s %s\n' "SERVICE" "STATE" "DETAIL"
printf '%-22s %-8s %s\n' "-------" "-----" "------"

while IFS= read -r entry; do
  name=$(jq -r '.name' <<<"$entry")
  health=$(jq -r '.health' <<<"$entry")
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$health" 2>/dev/null || echo "000")
  if [[ "$code" == 000* ]]; then
    printf '%-22s \033[31m%-8s\033[0m %s\n' "$name" "DOWN" "$health"
    FAILED=1
  else
    printf '%-22s \033[32m%-8s\033[0m %s (HTTP %s)\n' "$name" "UP" "$health" "$code"
  fi
done < <(jq -c '.services[]' "$LIB/services.json")

echo
printf '%-22s %-8s\n' "MODEL" "STATE"
printf '%-22s %-8s\n' "-----" "-----"

if command -v ollama >/dev/null 2>&1; then
  while IFS= read -r model; do
    if ollama list 2>/dev/null | awk 'NR > 1 { print $1; sub(/:latest$/, "", $1); print $1 }' | grep -qx "$model"; then
      printf '%-22s \033[32m%-8s\033[0m\n' "$model" "PULLED"
    else
      printf '%-22s \033[31m%-8s\033[0m\n' "$model" "MISSING"
      FAILED=1
    fi
  done < <(jq -r '.[]' "$LIB/models.json")
else
  echo "ollama CLI not found"
  FAILED=1
fi

exit $FAILED
