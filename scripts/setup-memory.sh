#!/usr/bin/env bash
set -Eeuo pipefail

readonly SWAPFILE="/swapfile"
readonly SWAP_SIZE_MB=4096

if [[ ! -f "${SWAPFILE}" ]]; then
  fallocate -l "${SWAP_SIZE_MB}M" "${SWAPFILE}"
  chmod 0600 "${SWAPFILE}"
  mkswap "${SWAPFILE}" >/dev/null
fi
swapon "${SWAPFILE}" 2>/dev/null || true
grep -qF "${SWAPFILE} none swap sw 0 0" /etc/fstab ||
  printf '%s\n' "${SWAPFILE} none swap sw 0 0" >> /etc/fstab

modprobe zram num_devices=1
zram_dev="/dev/zram0"
if [[ -b "${zram_dev}" ]]; then
  if ! swapon --show=NAME --noheadings | grep -qx "${zram_dev}"; then
    swapoff "${zram_dev}" 2>/dev/null || true
    zramctl --reset "${zram_dev}" 2>/dev/null || true
    zramctl --algorithm zstd --size 4G "${zram_dev}"
    mem_total_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    mem_limit_bytes="$((mem_total_kb * 1024 / 2))"
    printf '%s\n' "${mem_limit_bytes}" > "/sys/block/zram0/mem_limit"
    mkswap "${zram_dev}" >/dev/null
    swapon --priority 100 "${zram_dev}"
  fi
fi
