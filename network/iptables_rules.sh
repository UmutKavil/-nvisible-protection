#!/usr/bin/env bash
set -Eeuo pipefail

CHAIN="INVISIBLE_PROTECTION"
case "${1:-}" in
  apply)
    iptables -N "${CHAIN}" 2>/dev/null || true
    iptables -F "${CHAIN}"
    iptables -C DOCKER-USER -j "${CHAIN}" 2>/dev/null || iptables -I DOCKER-USER -j "${CHAIN}"
    iptables -A "${CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    for subnet in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
      iptables -A "${CHAIN}" -d "${subnet}" -j DROP
    done
    if [[ "${EGRESS_QUARANTINE:-0}" == "1" ]]; then
      iptables -A "${CHAIN}" -j DROP
    else
      iptables -A "${CHAIN}" -j RETURN
    fi
    ;;
  remove)
    iptables -D DOCKER-USER -j "${CHAIN}" 2>/dev/null || true
    iptables -F "${CHAIN}" 2>/dev/null || true
    iptables -X "${CHAIN}" 2>/dev/null || true
    ;;
  status) iptables -S "${CHAIN}" ;;
  *) echo "Kullanım: $0 {apply|remove|status}" >&2; exit 2 ;;
esac
