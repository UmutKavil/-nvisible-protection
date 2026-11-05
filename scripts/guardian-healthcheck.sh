#!/usr/bin/env bash
set -Eeuo pipefail

readonly DIONAEA_COMPOSE="/opt/guardian/docker/docker-compose.yml"
readonly COWRIE_COMPOSE="/opt/guardian/docker/cowrie/docker-compose.yml"
readonly CONFIG="/opt/guardian/config/guardian.conf"
readonly EVENT_LOG="/opt/guardian/logs/active/events.jsonl"
readonly MAX_DISK_PERCENT=90

enabled="$(awk -F= '$1 == "HONEYPOT_ENABLED" {print $2}' "${CONFIG}" 2>/dev/null || true)"
honeypot_type="$(awk -F= '$1 == "HONEYPOT_TYPE" {print $2}' "${CONFIG}" 2>/dev/null || true)"
if [[ "${enabled}" == "1" && "${honeypot_type}" == "dionaea" ]]; then
  docker compose -f "${DIONAEA_COMPOSE}" ps --status running --services |
    grep -qx "dionaea" ||
    { printf '%s\n' "Dionaea container is not running." >&2; exit 1; }
  docker inspect --format '{{.State.Health.Status}}' invisible-dionaea |
    grep -Eq 'healthy|starting' ||
    { printf '%s\n' "Dionaea container is unhealthy." >&2; exit 1; }
elif [[ "${enabled}" == "1" && "${honeypot_type}" == "cowrie" ]]; then
  docker compose -f "${COWRIE_COMPOSE}" ps --status running --services |
    grep -qx "cowrie" ||
    { printf '%s\n' "Cowrie container is not running." >&2; exit 1; }
fi

disk_percent="$(df -P /opt/guardian | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
[[ "${disk_percent}" =~ ^[0-9]+$ && "${disk_percent}" -lt "${MAX_DISK_PERCENT}" ]] ||
  { printf 'Guardian filesystem usage is too high: %s%%\n' "${disk_percent}" >&2; exit 1; }

[[ -f "${EVENT_LOG}" ]] || install -o root -g guardian -m 0640 /dev/null "${EVENT_LOG}"
