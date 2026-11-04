#!/usr/bin/env bash
set -Eeuo pipefail

readonly RAM_LOG="/var/log/guardian"
readonly DISK_LOG="/opt/guardian/logs/guardian-ram"
mkdir -p "${DISK_LOG}"
if [[ -d "${RAM_LOG}" ]]; then
  tar -C "${RAM_LOG}" -czf "${DISK_LOG}/latest.tar.gz" .
fi
