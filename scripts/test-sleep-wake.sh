#!/usr/bin/env bash
# test-sleep-wake.sh: End-to-end S5 sleep, Wake-on-LAN Magic Packet, boot timing & daemon verification
# Usage:
#   ./scripts/test-sleep-wake.sh
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

MESH_NODES=()
MESH_CONFIG="${MESH_CONFIG:-${HOME}/.config/mesh/cluster.conf}"
if [ -f "$MESH_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$MESH_CONFIG"
fi

if [ "${#MESH_NODES[@]}" -eq 0 ]; then
  echo "Error: No nodes configured. Run bootstrap-mesh.sh or create ${MESH_CONFIG}." >&2
  exit 1
fi

NODE_NAMES=()
NODE_IPS=()
for entry in "${MESH_NODES[@]}"; do
  IFS="|" read -r _name _ip _rest <<< "$entry"
  NODE_NAMES+=("$_name")
  NODE_IPS+=("$_ip")
done

echo "=== STEP 1: Dispatching mesh-power sleep ==="
mesh-power sleep

echo "=== STEP 2: Waiting for cluster nodes (${NODE_NAMES[*]}) to reach S5 power-off ==="
for i in {1..30}; do
  any_up=0
  for ip in "${NODE_IPS[@]}"; do
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      any_up=1
      break
    fi
  done
  if [ "$any_up" -eq 0 ]; then
    echo "All hosts ceased responding to ping after ${i}s; waiting 8s for PSU S5 latch..."
    sleep 8
    break
  fi
  sleep 1
done

echo "=== STEP 3: Verifying OFFLINE (S5 Standby) status ==="
mesh-power status

echo "=== STEP 4: Dispatching mesh-power wake ==="
t_wake=$(date +%s)
mesh-power wake

echo "=== STEP 5: Waiting for full SSH login readiness ==="
for i in {1..90}; do
  all_ssh=1
  for name in "${NODE_NAMES[@]}"; do
    if ! ssh -o ConnectTimeout=1 "$name" "true" >/dev/null 2>&1; then
      all_ssh=0
      break
    fi
  done
  if [ "$all_ssh" -eq 1 ]; then
    t_ready=$(date +%s)
    echo "All hosts unlocked SSH login in $((t_ready - t_wake))s from Magic Packet!"
    break
  fi
  sleep 1
done

echo "=== STEP 6: Verifying mesh-power status, clocksource, NIC/BIOS state, systemd-analyze & agy daemon ==="
mesh-power status
for name in "${NODE_NAMES[@]}"; do
  echo "--- [ ${name} ] ---"
  ssh -T "$name" '
    cat /sys/devices/system/clocksource/clocksource0/current_clocksource
    lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINTS
    if command -v cctk >/dev/null 2>&1; then
      sudo cctk --EmbNic2 --Serial1 --IntegratedAudio --Sata4 --Sata5 2>/dev/null || true
    fi
    ip -br link
    systemd-analyze
    systemd-analyze blame | head -n 5
    agy remote-control status 2>/dev/null || true
  '
done
