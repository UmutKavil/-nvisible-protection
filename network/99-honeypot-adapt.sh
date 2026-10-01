#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG="/opt/guardian/config/guardian.conf"
[[ -r "${CONFIG}" ]] || exit 0
source "${CONFIG}"
case "${2:-}" in
  up|dhcp4-change|connectivity-change)
    if [[ "${PRIMARY_INTERFACE:-auto}" != "auto" && "${1}" != "${PRIMARY_INTERFACE}" ]]; then
      while ip route del default dev "${1}" 2>/dev/null; do :; done
    fi
    if [[ "${EGRESS_QUARANTINE:-0}" == "1" ]]; then
      /opt/guardian/network/iptables_rules.sh apply
    fi
    ;;
esac
