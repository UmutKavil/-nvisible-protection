#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_DIR="/var/log/guardian"
readonly LOG_FILE="${LOG_DIR}/temperature.log"
mkdir -p "${LOG_DIR}"
temperature="$(vcgencmd measure_temp 2>/dev/null | sed -n "s/.*=\([0-9.]*\).*/\1/p" || true)"
if [[ -z "${temperature}" ]]; then
  thermal_file="/sys/class/thermal/thermal_zone0/temp"
  if [[ -r "${thermal_file}" ]]; then
    temperature="$(awk '{printf "%.1f", $1 / 1000}' "${thermal_file}")"
  else
    printf '%s level=ERROR message=temperature_source_unavailable\n' \
      "$(date --iso-8601=seconds)" >> "${LOG_FILE}"
    exit 0
  fi
fi

level=INFO
awk "BEGIN {exit !(${temperature} >= 85)}" && level=CRITICAL
if [[ "${level}" == INFO ]] && awk "BEGIN {exit !(${temperature} >= 80)}"; then
  level=WARNING
fi
printf '%s level=%s temperature_c=%s\n' "$(date --iso-8601=seconds)" "${level}" "${temperature}" >> "${LOG_FILE}"
