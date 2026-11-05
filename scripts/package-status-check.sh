#!/usr/bin/env bash
set -Eeuo pipefail

# Apt kilidi çakışması Guardian servislerinin açılışını etkilemesin.
readonly LOCK_FILE="/run/guardian-package-status.lock"
readonly EVENT_LOG="/opt/guardian/logs/active/events.jsonl"
readonly LOCK_WAIT_SECONDS=120

exec 9>"${LOCK_FILE}"
if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
  printf '%s\n' "Apt kilidi alınamadı; paket kontrolü atlandı." >&2
  exit 0
fi

if ! apt-get -o Acquire::Retries=3 update; then
  printf '%s\n' "Paket listesi güncellenemedi." >&2
  exit 0
fi

upgradable="$(apt list --upgradable 2>/dev/null | awk 'NR > 1 && NF {count++} END {print count + 0}')"
timestamp="$(date +%s)"
install -d -m 0750 -o root -g guardian "$(dirname "${EVENT_LOG}")"
printf '{"ts":%s,"tip":"PACKAGE_STATUS","detay":{"upgradable":%s},"severity":"düşük","group_key":"package-status"}\n' \
  "${timestamp}" "${upgradable}" >> "${EVENT_LOG}"
printf 'Yükseltilebilir paket sayısı: %s\n' "${upgradable}"
