#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPOSE_FILE="/opt/guardian/docker/docker-compose.yml"
readonly EVENT_LOG="/opt/guardian/logs/active/events.jsonl"
readonly MAX_DISK_PERCENT=90

docker compose -f "${COMPOSE_FILE}" ps --status running --services |
  grep -qx "dionaea" ||
  { printf '%s\n' "Dionaea container is not running." >&2; exit 1; }

docker inspect --format '{{.State.Health.Status}}' invisible-dionaea |
  grep -Eq 'healthy|starting' ||
  { printf '%s\n' "Dionaea container is unhealthy." >&2; exit 1; }

disk_percent="$(df -P /opt/guardian | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
[[ "${disk_percent}" =~ ^[0-9]+$ && "${disk_percent}" -lt "${MAX_DISK_PERCENT}" ]] ||
  { printf 'Guardian filesystem usage is too high: %s%%\n' "${disk_percent}" >&2; exit 1; }

[[ -f "${EVENT_LOG}" ]] || install -o root -g guardian -m 0640 /dev/null "${EVENT_LOG}"
