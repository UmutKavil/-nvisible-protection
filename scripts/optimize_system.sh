#!/usr/bin/env bash
set -Eeuo pipefail

# Bu script root olarak çalıştırılmalıdır; sistem paketleri ve çekirdek ayarları değişir.
[[ "${EUID}" -eq 0 ]] || { printf 'Root yetkisi gerekli.\n' >&2; exit 1; }

readonly SYSCTL_FILE="/etc/sysctl.d/99-performance.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-guardian.conf"
readonly CPUFREQ_FILE="/etc/default/cpufrequtils"
readonly INTERFACE="${GUARDIAN_INTERFACE:-eth0}"
readonly PACKAGES=(irqbalance ethtool iotop sysstat cpufrequtils lm-sensors stress-ng nftables)

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "${PACKAGES[@]}"
modprobe tcp_bbr 2>/dev/null || true

# Bu servisler Pi üzerinde kullanılmıyorsa kaynak tüketimini ve arka plan yazımını azaltır.
for service in snapd.service cloud-init.service packagekit.service; do
  systemctl disable --now "${service}" 2>/dev/null || true
  systemctl mask "${service}" 2>/dev/null || true
done

cat > "${SYSCTL_FILE}" <<'EOF'
# Guardian ağ gözleminde paket kuyruklarını ve TCP davranışını dengeler.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_moderate_rcvbuf = 1
fs.file-max = 2097152
EOF
if ! sysctl --system; then
  printf 'sysctl performans ayarları uygulanamadı.\n' >&2
  exit 1
fi

cat > "${LIMITS_FILE}" <<'EOF'
guardian soft nofile 65536
guardian hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF

systemctl enable --now irqbalance.service
systemctl enable --now fstrim.timer

cat > "${CPUFREQ_FILE}" <<'EOF'
GOVERNOR="ondemand"
EOF
systemctl enable --now cpufrequtils.service 2>/dev/null || true

# Wake-on-LAN kapatılır; başarısızlık desteklenmeyen NIC'lerde açıkça loglanır.
if ! ethtool -s "${INTERFACE}" wol d; then
  printf 'Wake-on-LAN kapatılamadı: %s\n' "${INTERFACE}" >&2
fi

printf 'Guardian sistem optimizasyonu tamamlandı.\n'
