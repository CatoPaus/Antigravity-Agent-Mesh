#!/usr/bin/env bash
# bootstrap-mesh.sh: Master Control-Plane & Multi-Node Cluster Orchestrator
#
# Deploys the control-plane CLI tools (bin/mesh-{power,sync,acp,hygiene}),
# generates ~/.config/mesh/cluster.conf, configures SSH ControlMaster multiplexing,
# registers NUMA ACP subagents in Antigravity settings.json, installs global Lead Agent
# routing rules (rules/mesh-cluster.md), and provisions remote nodes via provision-node.sh.
#
# Usage:
#   ./bootstrap-mesh.sh [OPTIONS]
#
# Node & Network Options:
#   --node <alias=ip[,mac[,persona]]>  Add a cluster node (repeatable; e.g. --node node1=192.168.1.210,,tars)
#   --user <username>                  SSH username on cluster nodes (default: ag-worker)
#   --bcast <ip>                       Subnet broadcast IP for Wake-on-LAN (default: auto from node1 IP /24)
#   --primary-nic <iface>              Primary WoL NIC on remote nodes (default: auto-detected)
#   --secondary-nic <iface>            Optional unused secondary NIC to power off (default: none)
#
# Provisioning Options (forwarded to provision-node.sh):
#   --with-eda                         Install KiCad 10 + JRE + freerouting.jar on nodes
#   --with-embedded                    Install ARM bare-metal GCC toolchain on nodes
#   --no-tts                           Disable chassis speaker TTS setup
#   --dell-bios / --no-dell-bios       Force or skip Dell cctk BIOS tuning (default: auto-detect)
#   --scratch-disk <dev>               Scratch SSD device for /opt/mesh (default: /dev/sdb)
#   --idle-minutes <N>                 Idle S5 standby timeout in minutes (0 disables, default: 30)
#   --ccache-size <size>               Shared ccache limit (default: 25.0G)
#
# Actions:
#   --control-plane-only               Configure local workstation only (do not wake/provision nodes)
#   --provision-nodes                  Stream provision-node.sh to all configured nodes in parallel
#   --sync-auth                        Copy local ~/.gemini/antigravity-cli auth & start remote daemons
#   --reboot-nodes                     Reboot nodes to latch BIOS settings & wait for SSH readiness
#   --verify                           Run control-plane & multi-socket health audit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESH_CONFIG="${MESH_CONFIG:-${HOME}/.config/mesh/cluster.conf}"

RAW_NODES=()
REMOTE_USER=""
BCAST=""
PRIMARY_NIC=""
SECONDARY_NIC=""
IDLE_LIMIT_MIN=""
CCACHE_SIZE=""
SCRATCH_DISK=""
WITH_EDA=0
WITH_EMBEDDED=0
NO_TTS=0
DELL_BIOS_FLAG=""

CONTROL_PLANE_ONLY=0
DO_PROVISION_NODES=0
DO_SYNC_AUTH=0
DO_REBOOT_NODES=0
DO_VERIFY=0
EXPLICIT_ACTION=0

while [ $# -gt 0 ]; do
  case "$1" in
    --node) RAW_NODES+=("${2:?Missing value for --node}"); shift ;;
    --user) REMOTE_USER="${2:?Missing value for --user}"; shift ;;
    --bcast) BCAST="${2:?Missing value for --bcast}"; shift ;;
    --primary-nic) PRIMARY_NIC="${2:?Missing value for --primary-nic}"; shift ;;
    --secondary-nic) SECONDARY_NIC="${2:?Missing value for --secondary-nic}"; shift ;;
    --idle-minutes) IDLE_LIMIT_MIN="${2:?Missing value for --idle-minutes}"; shift ;;
    --ccache-size) CCACHE_SIZE="${2:?Missing value for --ccache-size}"; shift ;;
    --scratch-disk) SCRATCH_DISK="${2:?Missing value for --scratch-disk}"; shift ;;
    --with-eda) WITH_EDA=1 ;;
    --with-embedded) WITH_EMBEDDED=1 ;;
    --no-tts) NO_TTS=1 ;;
    --dell-bios) DELL_BIOS_FLAG="--dell-bios" ;;
    --no-dell-bios) DELL_BIOS_FLAG="--no-dell-bios" ;;
    --control-plane-only) CONTROL_PLANE_ONLY=1; EXPLICIT_ACTION=1 ;;
    --provision-nodes) DO_PROVISION_NODES=1; EXPLICIT_ACTION=1 ;;
    --sync-auth) DO_SYNC_AUTH=1; EXPLICIT_ACTION=1 ;;
    --reboot-nodes) DO_REBOOT_NODES=1; EXPLICIT_ACTION=1 ;;
    --verify|--verify-only) DO_VERIFY=1; EXPLICIT_ACTION=1 ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ "$EXPLICIT_ACTION" -eq 0 ]; then
  DO_PROVISION_NODES=1
  DO_VERIFY=1
fi

step() {
  printf "\n======================================================================\n"
  printf ">>> %s\n" "$*"
  printf "======================================================================\n"
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  elif [ -x /mnt/c/Windows/System32/wsl.exe ] && [ -n "${WSL_DISTRO_NAME:-}" ]; then
    /mnt/c/Windows/System32/wsl.exe -d "$WSL_DISTRO_NAME" -u root -- "$@"
  else
    sudo "$@"
  fi
}

# Verify required repository files
for req in provision-node.sh bin/mesh-power bin/mesh-sync bin/mesh-acp bin/mesh-hygiene rules/mesh-cluster.md; do
  if [ ! -f "${SCRIPT_DIR}/${req}" ]; then
    echo "Error: Missing required file ${SCRIPT_DIR}/${req}" >&2
    exit 1
  fi
done

# Load existing cluster.conf if present and no --node overrides were provided
NODE_SPECS=()
if [ "${#RAW_NODES[@]}" -eq 0 ] && [ -f "$MESH_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$MESH_CONFIG"
  REMOTE_USER="${REMOTE_USER:-${MESH_USER:-ag-worker}}"
  BCAST="${BCAST:-${MESH_BCAST:-}}"
  PRIMARY_NIC="${PRIMARY_NIC:-${MESH_PRIMARY_NIC:-}}"
  SECONDARY_NIC="${SECONDARY_NIC:-${MESH_SECONDARY_NIC:-}}"
  IDLE_LIMIT_MIN="${IDLE_LIMIT_MIN:-${MESH_IDLE_MINUTES:-30}}"
  NODE_SPECS=("${MESH_NODES[@]}")
else
  REMOTE_USER="${REMOTE_USER:-ag-worker}"
  IDLE_LIMIT_MIN="${IDLE_LIMIT_MIN:-30}"
  if [ "${#RAW_NODES[@]}" -eq 0 ]; then
    RAW_NODES=("node1=192.168.1.210,,tars" "node2=192.168.1.211,,case")
  fi
  idx=0
  for spec in "${RAW_NODES[@]}"; do
    alias="${spec%%=*}"
    rest="${spec#*=}"
    if [ "$alias" = "$spec" ] || [ -z "$alias" ] || [ -z "$rest" ]; then
      echo "Error: Invalid --node '$spec'. Expected format: alias=ip[,mac[,persona]]" >&2
      exit 1
    fi
    IFS="," read -r ip mac_or_empty persona <<< "$rest"
    mac="${mac_or_empty//-/:}"
    if [ -z "$persona" ]; then
      persona=$([ $((idx % 2)) -eq 0 ] && echo "tars" || echo "case")
    fi
    NODE_SPECS+=("${alias}|${ip}|${mac:-00:00:00:00:00:00}|2|${persona}|NUMA Worker ${alias}")
    idx=$((idx + 1))
  done
fi

if [ -z "$BCAST" ]; then
  first_ip="${NODE_SPECS[0]#*|}"
  first_ip="${first_ip%%|*}"
  BCAST="${first_ip%.*}.255"
fi

CCACHE_SIZE="${CCACHE_SIZE:-25.0G}"
SCRATCH_DISK="${SCRATCH_DISK:-/dev/sdb}"

# ------------------------------------------------------------------------------
# Stage 1-4: Configure Control Plane
# ------------------------------------------------------------------------------
setup_control_plane() {
  step "Stage 1: Installing Control-Plane Dependencies & SSH Multiplexing"

  if ! command -v wakeonlan >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wakeonlan jq openssh-client python3
  fi

  mkdir -p "$HOME/.ssh/controlmasters" "$(dirname "$MESH_CONFIG")"
  chmod 700 "$HOME/.ssh" "$HOME/.ssh/controlmasters"
  touch "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"

  UPDATED_NODES=()
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias ip mac numas persona desc <<< "$entry"

    if ! grep -q "^Host ${alias} " "$HOME/.ssh/config" 2>/dev/null; then
      cat <<EOF >> "$HOME/.ssh/config"

Host ${alias} ${ip}
  HostName ${ip}
  User ${REMOTE_USER}
  ControlMaster auto
  ControlPath ~/.ssh/controlmasters/%r@%h:%p
  ControlPersist 4h
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF
      echo "Added 'Host ${alias}' (${ip}) to ~/.ssh/config"
    fi

    # Auto-discover live MAC, NUMA node count, and CPU summary if reachable
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      probe_nic="${PRIMARY_NIC}"
      if [ -z "$probe_nic" ]; then
        probe_nic=$(ssh -o ConnectTimeout=2 "$alias" "ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}'" 2>/dev/null || true)
      fi
      if [ -n "$probe_nic" ]; then
        live_mac=$(ssh -o ConnectTimeout=2 "$alias" "cat /sys/class/net/${probe_nic}/address" 2>/dev/null || true)
        [ -n "$live_mac" ] && mac="$live_mac"
      fi
      live_numas=$(ssh -o ConnectTimeout=2 "$alias" "ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l" 2>/dev/null || true)
      if [[ "$live_numas" =~ ^[0-9]+$ ]] && [ "$live_numas" -ge 1 ]; then
        numas="$live_numas"
      fi
      live_cpu=$(ssh -o ConnectTimeout=2 "$alias" "lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/, \"\", \$2); print \$2; exit}'" 2>/dev/null || true)
      live_threads=$(ssh -o ConnectTimeout=2 "$alias" "nproc" 2>/dev/null || true)
      live_ram=$(ssh -o ConnectTimeout=2 "$alias" "awk '/MemTotal/{printf \"%dG\", (\$2+524288)/1048576}' /proc/meminfo" 2>/dev/null || true)
      if [ -n "$live_cpu" ]; then
        desc="${live_cpu} (${live_threads:-?}T, ${live_ram:-?} RAM)"
      fi
    fi

    UPDATED_NODES+=("${alias}|${ip}|${mac}|${numas}|${persona}|${desc}")
  done
  NODE_SPECS=("${UPDATED_NODES[@]}")

  step "Stage 2: Writing ${MESH_CONFIG} & Installing /usr/local/bin/mesh-*"

  {
    echo "# Antigravity Agent Mesh — Control-Plane Configuration"
    echo "# Generated by bootstrap-mesh.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "MESH_USER=\"${REMOTE_USER}\""
    echo "MESH_BCAST=\"${BCAST}\""
    echo "MESH_PRIMARY_NIC=\"${PRIMARY_NIC}\""
    echo "MESH_SECONDARY_NIC=\"${SECONDARY_NIC}\""
    echo "MESH_IDLE_MINUTES=\"${IDLE_LIMIT_MIN}\""
    echo "MESH_NODES=("
    for entry in "${NODE_SPECS[@]}"; do
      echo "  \"${entry}\""
    done
    echo ")"
  } > "$MESH_CONFIG"
  chmod 600 "$MESH_CONFIG"

  for tool in mesh-power mesh-sync mesh-acp mesh-hygiene; do
    run_root cp "${SCRIPT_DIR}/bin/${tool}" "/usr/local/bin/${tool}"
    run_root chmod +x "/usr/local/bin/${tool}"
  done
  ls -lh /usr/local/bin/mesh-power /usr/local/bin/mesh-sync /usr/local/bin/mesh-acp /usr/local/bin/mesh-hygiene

  step "Stage 3: Registering NUMA Subagents in Antigravity settings.json"

  ACP_JSON="{"
  first_acp=1
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias ip mac numas persona desc <<< "$entry"
    for ((n=0; n<numas; n++)); do
      [ "$first_acp" -eq 0 ] && ACP_JSON+=","
      first_acp=0
      ACP_JSON+="\"${alias}-node${n}\":{\"command\":\"ssh\",\"args\":[\"-T\",\"${alias}\",\"/usr/local/bin/ag-acp-worker\",\"${n}\",\"node${n}\"],\"description\":\"${alias} NUMA Node ${n} (${desc})\"}"
    done
  done
  ACP_JSON+="}"

  for subdir in antigravity antigravity-cli; do
    mkdir -p "$HOME/.gemini/$subdir"
    SETTINGS_FILE="$HOME/.gemini/$subdir/settings.json"
    [ -s "$SETTINGS_FILE" ] || echo "{}" > "$SETTINGS_FILE"
    jq --argjson servers "$ACP_JSON" '.acpServers = ((.acpServers // {}) + $servers)' \
      "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo "Updated ACP server registry in $SETTINGS_FILE"
  done

  step "Stage 4: Installing Global Antigravity 2.0 Routing Rules"

  TOPOLOGY_LINES=""
  SAMPLE_TARGET=""
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias ip mac numas persona desc <<< "$entry"
    [ -z "$SAMPLE_TARGET" ] && SAMPLE_TARGET="${alias}-node0"
    node_list=""
    for ((n=0; n<numas; n++)); do
      node_list+="${alias}-node${n}"
      [ "$n" -lt $((numas - 1)) ] && node_list+=" & "
    done
    TOPOLOGY_LINES+="- ${node_list} (\`${ip}\`, SSH user \`${REMOTE_USER}\` via alias \`${alias}\`): ${desc} (${numas} NUMA node(s))."$'\n'
  done

  mkdir -p \
    "$HOME/.gemini/config/rules" \
    "$HOME/.gemini/antigravity/rules" \
    "$HOME/.gemini/antigravity-cli/rules"

  RENDERED_RULE=$(mktemp)
  python3 - "$SCRIPT_DIR/rules/mesh-cluster.md" "$RENDERED_RULE" "$REMOTE_USER" "$TOPOLOGY_LINES" "$SAMPLE_TARGET" <<'PYEOF'
import sys
src, dst, user, topo, sample = sys.argv[1:6]
with open(src, "r", encoding="utf-8") as f:
    txt = f.read()
txt = txt.replace("{{MESH_USER}}", user)
txt = txt.replace("{{CLUSTER_TOPOLOGY}}", topo.rstrip("\n"))
txt = txt.replace("{{SAMPLE_TARGET}}", sample)
with open(dst, "w", encoding="utf-8") as f:
    f.write(txt)
PYEOF

  cp "$RENDERED_RULE" "$HOME/.gemini/GEMINI.md"
  cp "$RENDERED_RULE" "$HOME/.gemini/config/rules/mesh-cluster.md"
  cp "$RENDERED_RULE" "$HOME/.gemini/antigravity/rules/mesh-cluster.md"
  cp "$RENDERED_RULE" "$HOME/.gemini/antigravity-cli/rules/mesh-cluster.md"
  echo "Installed rendered mesh-cluster.md into ~/.gemini/ paths."

  if [ -d /mnt/c/Users ]; then
    WIN_USER=""
    if [ -x /mnt/c/Windows/System32/cmd.exe ]; then
      WIN_USER=$(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || true)
    fi
    if [ -n "$WIN_USER" ] && [ -d "/mnt/c/Users/${WIN_USER}" ]; then
      mkdir -p "/mnt/c/Users/${WIN_USER}/.gemini/config/rules"
      cp "$RENDERED_RULE" "/mnt/c/Users/${WIN_USER}/.gemini/GEMINI.md"
      cp "$RENDERED_RULE" "/mnt/c/Users/${WIN_USER}/.gemini/config/rules/mesh-cluster.md"
      echo "Installed rendered mesh-cluster.md into C:\\Users\\${WIN_USER}\\.gemini\\ paths."
    fi
  fi
  rm -f "$RENDERED_RULE"
}

# ------------------------------------------------------------------------------
# Stage 5: Provision Remote Nodes in Parallel
# ------------------------------------------------------------------------------
provision_remote_nodes() {
  step "Stage 5: Ensuring Cluster is Awake & Running provision-node.sh in Parallel"
  /usr/local/bin/mesh-power ensure

  PROV_ARGS=("--user" "$REMOTE_USER" "--idle-minutes" "$IDLE_LIMIT_MIN" "--ccache-size" "$CCACHE_SIZE" "--scratch-disk" "$SCRATCH_DISK")
  [ -n "$PRIMARY_NIC" ] && PROV_ARGS+=("--primary-nic" "$PRIMARY_NIC")
  [ -n "$SECONDARY_NIC" ] && PROV_ARGS+=("--secondary-nic" "$SECONDARY_NIC")
  [ "$WITH_EDA" -eq 1 ] && PROV_ARGS+=("--with-eda")
  [ "$WITH_EMBEDDED" -eq 1 ] && PROV_ARGS+=("--with-embedded")
  [ "$NO_TTS" -eq 1 ] && PROV_ARGS+=("--no-tts")
  [ -n "$DELL_BIOS_FLAG" ] && PROV_ARGS+=("$DELL_BIOS_FLAG")

  OPERATOR_NAME="$(whoami)"
  pids=()
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias _ip _mac _numas persona _desc <<< "$entry"
    (
      ssh -T "$alias" "AG_OPERATOR=$(printf '%q' "$OPERATOR_NAME") AG_PERSONA=$(printf '%q' "$persona") bash -s -- $(printf '%q ' "${PROV_ARGS[@]}")" < "${SCRIPT_DIR}/provision-node.sh"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
}

# ------------------------------------------------------------------------------
# Stage 6: Sync Antigravity OAuth Credentials & Enable Remote Control Daemon
# ------------------------------------------------------------------------------
sync_remote_auth() {
  step "Stage 6: Syncing Antigravity OAuth Credentials & Starting Remote Control Daemons"
  /usr/local/bin/mesh-power ensure

  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias _ip _mac _numas _persona _desc <<< "$entry"
    if [ -d "$HOME/.gemini/antigravity-cli" ]; then
      tar -C "$HOME" -cf - .gemini/antigravity-cli 2>/dev/null | ssh -T "$alias" "tar -C \$HOME -xf -" || true
    fi
    ssh -T "$alias" "
      export PATH=\"\$HOME/.local/bin:\$PATH\"
      sudo loginctl enable-linger \"\$(id -un)\"
      agy remote-control start --name '$alias' 2>/dev/null || true
      systemctl --user daemon-reload 2>/dev/null || true
      systemctl --user restart antigravity-cli-daemon.service 2>/dev/null || true
      agy remote-control status || true
    "
  done
}

# ------------------------------------------------------------------------------
# Stage 7: Reboot Nodes to Latch BIOS Settings
# ------------------------------------------------------------------------------
reboot_nodes() {
  step "Stage 7: Rebooting Cluster Nodes to Latch BIOS Settings"
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r alias _ip _mac _numas _persona _desc <<< "$entry"
    ssh -o ConnectTimeout=5 "$alias" "sudo reboot" 2>/dev/null || true
    ssh -O exit "$alias" 2>/dev/null || true
  done
  echo "Waiting 15s for nodes to enter POST..."
  sleep 15
  /usr/local/bin/mesh-power ensure
}

# ------------------------------------------------------------------------------
# Verification Suite
# ------------------------------------------------------------------------------
verify_cluster() {
  step "Verification: Control-Plane & Cluster Health Audit"

  echo "=== 1. Control-Plane Entrypoints, Config & Rule Mirrors ==="
  ls -lh /usr/local/bin/mesh-power /usr/local/bin/mesh-sync /usr/local/bin/mesh-acp /usr/local/bin/mesh-hygiene \
    "$MESH_CONFIG" "$HOME/.gemini/GEMINI.md" "$HOME/.gemini/config/rules/mesh-cluster.md"

  echo "=== 2. Registered ACP Subagents in settings.json ==="
  jq -r '.acpServers | keys[]' "$HOME/.gemini/antigravity-cli/settings.json" | sed 's/^/  - /'

  echo "=== 3. Cluster Power & Load Status ==="
  /usr/local/bin/mesh-power status

  all_up=1
  for entry in "${NODE_SPECS[@]}"; do
    IFS="|" read -r _alias ip _rest <<< "$entry"
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1 || { all_up=0; break; }
  done

  if [ "$all_up" -eq 1 ]; then
    echo "=== 4. Remote Node Storage, Caches & Binaries ==="
    for entry in "${NODE_SPECS[@]}"; do
      IFS="|" read -r alias _ip _mac _numas _persona _desc <<< "$entry"
      ssh -T "$alias" "
        printf '[%-10s] /opt/mesh free: %s | ccache: %s | binaries: %s\n' \
          '$alias' \
          \"\$(df -h /opt/mesh | awk 'NR==2{print \$4}')\" \
          \"\$(CCACHE_DIR=/opt/mesh/cache/ccache ccache -s | awk '/Cache size/{print \$4, \$5, \$6}')\" \
          \"\$(ls /usr/local/bin/ag-numa-exec /usr/local/bin/ag-acp-worker /usr/local/bin/ag-mesh-worktree /usr/local/bin/ag-idle-watchdog 2>/dev/null | wc -l)/4 core ok\"
      "
    done

    echo "=== 5. Multi-Socket NUMA & Cgroup Isolation Probe ==="
    for entry in "${NODE_SPECS[@]}"; do
      IFS="|" read -r alias _ip _mac numas _persona _desc <<< "$entry"
      for ((node=0; node<numas; node++)); do
        ssh -T "$alias" "ag-numa-exec $node bash -s" << 'EOF' &
          CPUS=$(awk '/Cpus_allowed_list:/{print $2}' /proc/self/status)
          MEMS=$(awk '/Mems_allowed_list:/{print $2}' /proc/self/status)
          CGRP=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
          FREQ=$(awk '{sum+=$1; n++} END {if(n>0) printf "%.0f MHz", sum/n/1000; else print "n/a"}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || echo "n/a")
          printf "[%-10s | node%s] CPUs: %-13s | RAM Node: %s | Avg Clock: %-8s | Slice: %s\n" \
            "$(hostname)" "$MEMS" "$CPUS" "$MEMS" "$FREQ" "$CGRP"
EOF
      done
    done
    wait
  else
    echo "Note: One or more nodes are in S5 standby (skipping live SSH probes)."
    echo "      Run 'mesh-power ensure' or 'mesh-acp all ...' to wake them automatically."
  fi
}

setup_control_plane

if [ "$CONTROL_PLANE_ONLY" -eq 1 ]; then
  [ "$DO_VERIFY" -eq 1 ] && verify_cluster
  exit 0
fi

[ "$DO_PROVISION_NODES" -eq 1 ] && provision_remote_nodes
[ "$DO_SYNC_AUTH" -eq 1 ] && sync_remote_auth
[ "$DO_REBOOT_NODES" -eq 1 ] && reboot_nodes
[ "$DO_VERIFY" -eq 1 ] && verify_cluster
