#!/usr/bin/env bash
set -Eeuo pipefail

# vcgencmd yoksa veya komut başarısızsa sessizce başarılı sayılmaz; journal'a hata yazılır.
readonly EVENT_LOG="/opt/guardian/logs/active/events.jsonl"
output="$(vcgencmd get_throttled 2>&1)" || {
  printf 'vcgencmd get_throttled başarısız: %s\n' "${output}" >&2
  exit 1
}
code="${output#throttled=}"
if [[ "${code}" != "0x0" ]]; then
  install -d -m 0750 -o root -g guardian "$(dirname "${EVENT_LOG}")"
  printf '{"ts":%s,"tip":"THERMAL_THROTTLE","detay":{"kod":"%s"},"severity":"kritik","group_key":"thermal"}\n' \
    "$(date +%s.%N)" "${code}" >> "${EVENT_LOG}"
fi
