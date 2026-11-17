#!/usr/bin/env bash
# provision-node.sh: Idempotent turnkey provisioner for NUMA Antigravity Mesh Nodes
#
# Transforms a fresh Ubuntu Server LTS installation (with OpenSSH + passwordless sudo) into a
# hardware-pinned multi-socket NUMA compute node with:
#   1. LVM root expansion + dedicated /opt/mesh ext4 scratch SSD (LABEL=mesh_scratch)
#   2. Core build/NUMA/monitoring packages + optional --with-eda (KiCad/Freerouting) & --with-embedded (ARM GCC)
#   3. Optional Dell Command | Configure (cctk) headless BIOS tuning (auto-detected on Dell hardware)
#   4. Boot/udev/service debloat, Netplan Wake-on-LAN, wol-<nic>.service, cpufreq-performance.service
#   5. Dynamic Cgroup v2 resource slice (antigravity.slice) + /usr/local/bin/ag-numa-exec
#   6. TARS / CASE offline chassis speaker TTS (/usr/local/bin/ag-notify, opt-out via --no-tts)
#   7. Shared /opt/mesh/cache (ccache, cargo, npm, pip) + ag-acp-worker + ag-mesh-worktree
#   8. Automatic idle S5 Wake-on-LAN standby watchdog (ag-idle-watchdog.timer)
#   9. Antigravity 2.0 CLI (agy) + antigravity-cli-daemon.service (Remote Control)
#
# Usage (run directly on node or via bootstrap-mesh.sh over SSH):
#   bash provision-node.sh [OPTIONS]
#
# Options:
#   --user <name>             Target non-root worker user (default: $SUDO_USER or current user)
#   --persona <tars|case>     Chassis TTS persona (default: $AG_PERSONA or tars)
#   --no-tts                  Skip ALSA/SoX/espeak-ng/MBROLA audio setup
#   --with-eda                Install KiCad 10 PPA, JRE headless, and freerouting.jar
#   --with-embedded           Install ARM Cortex-M bare-metal toolchain (gcc-arm-none-eabi)
#   --dell-bios               Force Dell cctk BIOS tuning
#   --no-dell-bios            Skip Dell cctk BIOS tuning even on Dell hardware
#   --primary-nic <iface>     Primary WoL NIC (default: auto-detected default route NIC)
#   --secondary-nic <iface>   Optional unused secondary NIC to power off in Netplan
#   --scratch-disk <dev>      Scratch block device for /opt/mesh (default: /dev/sdb)
#   --force-format-scratch    Reformat --scratch-disk as LABEL=mesh_scratch
#   --idle-minutes <N>        Idle minutes before S5 standby (0 disables watchdog, default: 30)
#   --ccache-size <size>      Max ccache size (default: 25.0G)
set -euo pipefail

FORCE_FORMAT_SCRATCH=0
IDLE_LIMIT_MIN=30
CCACHE_SIZE="25.0G"
PRIMARY_NIC=""
SECONDARY_NIC=""
SCRATCH_DISK="/dev/sdb"
WITH_EDA=0
WITH_EMBEDDED=0
ENABLE_TTS=1
DELL_BIOS_MODE="auto"
PERSONA="${AG_PERSONA:-tars}"
TARGET_USER="${SUDO_USER:-$(id -un)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:?Missing value for --user}"; shift ;;
    --persona) PERSONA="${2:?Missing value for --persona}"; shift ;;
    --no-tts) ENABLE_TTS=0 ;;
    --with-eda) WITH_EDA=1 ;;
    --with-embedded) WITH_EMBEDDED=1 ;;
    --dell-bios) DELL_BIOS_MODE="force" ;;
    --no-dell-bios) DELL_BIOS_MODE="skip" ;;
    --force-format-scratch) FORCE_FORMAT_SCRATCH=1 ;;
    --idle-minutes) IDLE_LIMIT_MIN="${2:?Missing value for --idle-minutes}"; shift ;;
    --ccache-size) CCACHE_SIZE="${2:?Missing value for --ccache-size}"; shift ;;
    --primary-nic) PRIMARY_NIC="${2:?Missing value for --primary-nic}"; shift ;;
    --secondary-nic) SECONDARY_NIC="${2:?Missing value for --secondary-nic}"; shift ;;
    --scratch-disk) SCRATCH_DISK="${2:?Missing value for --scratch-disk}"; shift ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$TARGET_USER" = "root" ] && [ -n "${AG_USER:-}" ]; then
  TARGET_USER="$AG_USER"
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "Error: Target user '$TARGET_USER' does not exist." >&2
  exit 1
fi
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
HOST_NAME="$(hostname)"

# Auto-detect hardware topology
TOTAL_CPUS=$(nproc)
NUMA_NODES=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
[ "$NUMA_NODES" -ge 1 ] || NUMA_NODES=1
PER_NODE_THREADS=$(( TOTAL_CPUS / NUMA_NODES ))
[ "$PER_NODE_THREADS" -ge 1 ] || PER_NODE_THREADS=1
MAKE_JOBS=$(( PER_NODE_THREADS > 2 ? PER_NODE_THREADS - 2 : PER_NODE_THREADS ))

OS_RESERVED_CPUS=$(( TOTAL_CPUS >= 16 ? 4 : (TOTAL_CPUS >= 8 ? 2 : 1) ))
SLICE_CPUS=$(( TOTAL_CPUS - OS_RESERVED_CPUS ))
[ "$SLICE_CPUS" -ge 1 ] || SLICE_CPUS=1
CPU_QUOTA=$(( SLICE_CPUS * 100 ))

TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%d", ($2 + 524288) / 1048576}' /proc/meminfo)
[ "$TOTAL_RAM_GB" -ge 2 ] || TOTAL_RAM_GB=2
MEM_HIGH_GB=$(( TOTAL_RAM_GB * 80 / 100 ))
[ "$MEM_HIGH_GB" -ge 1 ] || MEM_HIGH_GB=1
MEM_MAX_GB=$(( TOTAL_RAM_GB * 88 / 100 ))
[ "$MEM_MAX_GB" -gt "$MEM_HIGH_GB" ] || MEM_MAX_GB=$(( MEM_HIGH_GB + 1 ))

if [ -z "$PRIMARY_NIC" ]; then
  PRIMARY_NIC=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
  [ -n "$PRIMARY_NIC" ] || PRIMARY_NIC="enp0s25"
fi

log() {
  printf "\n[%s | %s] %s\n" "$HOST_NAME" "$(date +%H:%M:%S)" "$*"
}

log "Detected hardware: ${TOTAL_CPUS} threads across ${NUMA_NODES} NUMA node(s), ~${TOTAL_RAM_GB} GiB RAM, primary NIC ${PRIMARY_NIC}."

# ==============================================================================
# [1/9] Passwordless Sudo & Storage Layout (/ and /opt/mesh)
# ==============================================================================
log "[1/9] Configuring passwordless sudo and /opt/mesh storage layout..."

echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/90-${TARGET_USER}" >/dev/null
sudo chmod 0440 "/etc/sudoers.d/90-${TARGET_USER}"

if sudo lvdisplay /dev/ubuntu-vg/ubuntu-lv >/dev/null 2>&1; then
  sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv 2>/dev/null || true
  sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null || true
fi

if [ "$FORCE_FORMAT_SCRATCH" -eq 1 ] || ! sudo blkid -L mesh_scratch >/dev/null 2>&1; then
  if [ -b "$SCRATCH_DISK" ]; then
    log "Formatting scratch SSD $SCRATCH_DISK as ext4 (LABEL=mesh_scratch)..."
    sudo umount /opt/mesh 2>/dev/null || true
    sudo wipefs -a "$SCRATCH_DISK"
    sudo mkfs.ext4 -F -L mesh_scratch "$SCRATCH_DISK"
  else
    log "WARNING: Block device $SCRATCH_DISK not found and LABEL=mesh_scratch not present; using /opt/mesh on root filesystem."
  fi
else
  log "Existing LABEL=mesh_scratch detected; preserving /opt/mesh contents."
fi

sudo mkdir -p /opt/mesh
if sudo blkid -L mesh_scratch >/dev/null 2>&1; then
  if ! grep -q "LABEL=mesh_scratch" /etc/fstab; then
    echo "LABEL=mesh_scratch /opt/mesh ext4 defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  sudo mount -a
fi
sudo systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
sudo chown -R "${TARGET_USER}:${TARGET_USER}" /opt/mesh

# ==============================================================================
# [2/9] Base Packages, NUMA Utilities, Optional Toolchains & Audio Stack
# ==============================================================================
log "[2/9] Installing core packages, NUMA utilities, and ccache..."

CORE_PKGS=(
  build-essential cmake ninja-build
  git curl wget unzip jq htop btop
  numactl hwloc ethtool lm-sensors smartmontools ripgrep fd-find
  python3-pip python3-venv nodejs npm ccache
)

if [ "$WITH_EMBEDDED" -eq 1 ]; then
  log "Adding embedded ARM toolchain packages (--with-embedded)..."
  CORE_PKGS+=(gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib)
fi

if [ "$WITH_EDA" -eq 1 ]; then
  log "Adding KiCad 10 PPA & EDA packages (--with-eda)..."
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  if ! grep -rq "kicad-10_0-releases" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
    sudo add-apt-repository -y ppa:kicad/kicad-10.0-releases || log "Warning: KiCad 10 PPA skipped for codename ${CODENAME}."
  fi
  CORE_PKGS+=(default-jre-headless kicad)
fi

if [ "$ENABLE_TTS" -eq 1 ]; then
  CORE_PKGS+=(alsa-utils espeak-ng sox mbrola mbrola-us2 mbrola-us3 mbrola-en1)
fi

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${CORE_PKGS[@]}"
if [ "$ENABLE_TTS" -eq 1 ]; then
  sudo usermod -aG audio "$TARGET_USER"
fi

# ==============================================================================
# [3/9] Dell Command | Configure (cctk) & Headless BIOS Optimization
# ==============================================================================
SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
RUN_DELL_BIOS=0
if [ "$DELL_BIOS_MODE" = "force" ]; then
  RUN_DELL_BIOS=1
elif [ "$DELL_BIOS_MODE" = "auto" ] && echo "$SYS_VENDOR" | grep -qi "Dell"; then
  RUN_DELL_BIOS=1
fi

if [ "$RUN_DELL_BIOS" -eq 1 ]; then
  log "[3/9] Dell hardware detected (${SYS_VENDOR}); installing cctk and tuning BIOS..."
  if [ ! -x /opt/dell/dcc/cctk ]; then
    mkdir -p /tmp/dell-dcc
    (
      cd /tmp/dell-dcc
      curl -A "Mozilla/5.0" -fsSL -o dcc.tar.gz \
        "https://dl.dell.com/FOLDER12705845M/1/command-configure_5.1.0-6.ubuntu24_amd64.tar.gz"
      tar -xzf dcc.tar.gz
      sudo dpkg -i srvadmin-hapi_*.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
      sudo dpkg -i command-configure_*.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
    )
    rm -rf /tmp/dell-dcc
  fi
  sudo ln -sf /opt/dell/dcc/cctk /usr/local/bin/cctk

  BIOS_TOKENS=(
    "--CpuCores=All"
    "--Speedstep=Enabled"
    "--LogicProc=Enabled"
    "--TurboMode=Enabled"
    "--NodeInterleave=Enabled"
    "--CStatesCtrl=Enabled"
    "--HwPrefetcher=Enabled"
    "--AdjCachePrefetch=Enabled"
    "--AcPwrRcvry=Last"
    "--DeepSleepCtrl=Disabled"
    "--WakeOnLan=LanOnly"
    "--Virtualization=Enabled"
    "--VtForDirectIo=Enabled"
    "--EmbNic1=Enabled"
    "--EmbNic2=Disabled"
    "--IntegratedSas=Enabled"
    "--EmbSataRaid=Ahci"
    "--Sata4=Disabled"
    "--Sata5=Disabled"
    "--Serial1=Disabled"
    "--OromKeyboardAccess=Disabled"
    "--Fastboot=Minimal"
    "--RptKeyErr=Disabled"
  )
  if [ "$ENABLE_TTS" -eq 1 ]; then
    BIOS_TOKENS+=("--IntegratedAudio=Enabled")
  fi

  for token in "${BIOS_TOKENS[@]}"; do
    sudo /usr/local/bin/cctk "$token" >/dev/null 2>&1 || log "Note: cctk token $token skipped or not supported on this BIOS."
  done
else
  log "[3/9] Skipping Dell cctk BIOS tuning (vendor: '${SYS_VENDOR:-unknown}', mode: ${DELL_BIOS_MODE})."
fi

# ==============================================================================
# [4/9] Boot Tuning, Netplan Wake-on-LAN, Secondary NIC Off & CPU Governor
# ==============================================================================
log "[4/9] Configuring Wake-on-LAN (${PRIMARY_NIC}), service debloat, and performance CPU governor..."

if [ "$RUN_DELL_BIOS" -eq 1 ] && [ -f /etc/default/grub ]; then
  sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="8250.nr_uarts=0"/' /etc/default/grub
  sudo update-grub >/dev/null 2>&1 || true

  sudo tee /etc/udev/rules.d/99-disable-card-reader.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="0184", ATTR{authorized}="0"
EOF
  sudo udevadm control --reload-rules || true
fi

sudo systemctl disable --now \
  multipathd.service multipathd.socket udisks2.service ModemManager.service \
  apport.service snapd.service snapd.socket snapd.seeded.service \
  snapd.apparmor.service lxd-installer.socket 2>/dev/null || true
sudo systemctl mask \
  multipathd.service multipathd.socket udisks2.service ModemManager.service \
  apport.service 2>/dev/null || true

sudo tee "/etc/systemd/system/wol-${PRIMARY_NIC}.service" >/dev/null <<EOF
[Unit]
Description=Enable Wake-on-LAN on ${PRIMARY_NIC}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s ${PRIMARY_NIC} wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now "wol-${PRIMARY_NIC}.service" >/dev/null 2>&1 || true

if [ -n "$SECONDARY_NIC" ] && [ "$SECONDARY_NIC" != "$PRIMARY_NIC" ] && [ -d "/sys/class/net/${SECONDARY_NIC}" ]; then
  sudo tee /etc/netplan/00-installer-config.yaml >/dev/null <<EOF
network:
  ethernets:
    ${PRIMARY_NIC}:
      dhcp4: true
      wakeonlan: true
    ${SECONDARY_NIC}:
      dhcp4: false
      activation-mode: off
      optional: true
  version: 2
EOF
else
  sudo tee /etc/netplan/00-installer-config.yaml >/dev/null <<EOF
network:
  ethernets:
    ${PRIMARY_NIC}:
      dhcp4: true
      wakeonlan: true
  version: 2
EOF
fi
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan generate && sudo netplan apply

sudo tee /etc/systemd/system/cpufreq-performance.service >/dev/null <<'EOF'
[Unit]
Description=Set CPU scaling governor to performance across all cores
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$g" ] && echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now cpufreq-performance.service

# ==============================================================================
# [5/9] Cgroup v2 Slice (antigravity.slice) & NUMA Pinning (ag-numa-exec)
# ==============================================================================
log "[5/9] Installing antigravity.slice (${CPU_QUOTA}% CPU / ${MEM_MAX_GB}G RAM) and /usr/local/bin/ag-numa-exec..."

sudo tee /etc/systemd/system/antigravity.slice >/dev/null <<EOF
[Unit]
Description=Antigravity Agent Mesh Resource Slice (${HOST_NAME} ${TOTAL_RAM_GB}G / ${TOTAL_CPUS}T)
Before=slices.target

[Slice]
CPUAccounting=yes
CPUQuota=${CPU_QUOTA}%
MemoryAccounting=yes
MemoryHigh=${MEM_HIGH_GB}G
MemoryMax=${MEM_MAX_GB}G
TasksMax=16384
EOF
sudo systemctl daemon-reload

sudo tee /usr/local/bin/ag-numa-exec >/dev/null <<'EOF'
#!/usr/bin/env bash
# Usage: ag-numa-exec <0|1|...|interleave> <command...>
NODE="${1:-0}"
shift
NUMA_COUNT=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
if [ "$NODE" = "interleave" ] || [ "$NUMA_COUNT" -le 1 ]; then
  exec sudo systemd-run --quiet --scope --slice=antigravity.slice --uid="$(id -u)" --gid="$(id -g)" numactl --interleave=all "$@"
else
  exec sudo systemd-run --quiet --scope --slice=antigravity.slice -p AllowedMemoryNodes="$NODE" --uid="$(id -u)" --gid="$(id -g)" numactl --cpunodebind="$NODE" --membind="$NODE" "$@"
fi
EOF
sudo chmod +x /usr/local/bin/ag-numa-exec

# ==============================================================================
# [6/9] Offline Chassis Speaker TTS (ag-notify & ag-audio-online)
# ==============================================================================
if [ "$ENABLE_TTS" -eq 1 ]; then
  log "[6/9] Installing TARS/CASE chassis speaker TTS (/usr/local/bin/ag-notify, persona: ${PERSONA})..."

  echo "$PERSONA" | sudo tee /etc/ag-persona >/dev/null
  sudo chmod 0644 /etc/ag-persona

  if [ -n "${AG_OPERATOR:-}" ]; then
    echo "$AG_OPERATOR" | sudo tee /etc/ag-operator >/dev/null
    sudo chmod 0644 /etc/ag-operator
  elif [ ! -f /etc/ag-operator ]; then
    echo "$TARGET_USER" | sudo tee /etc/ag-operator >/dev/null
    sudo chmod 0644 /etc/ag-operator
  fi

  sudo tee /usr/local/bin/ag-notify >/dev/null <<'EOF'
#!/usr/bin/env bash
# Usage: ag-notify <online|offline|input|done|say> [custom message...]
set -uo pipefail

EVENT="${1:-say}"
shift || true
MSG="$*"
HOST="$(hostname)"
PERSONA="$(tr -d '\r\n' < /etc/ag-persona 2>/dev/null || echo tars)"
if [ "$PERSONA" = "none" ]; then
  exit 0
fi

CARD="PCH"
if ! aplay -l 2>/dev/null | grep -q "PCH"; then
  CARD="0"
fi

for ctl in Master Speaker PCM Front Headphone "Auto-Mute Mode"; do
  if [ "$ctl" = "Auto-Mute Mode" ]; then
    amixer -c "$CARD" -q sset "$ctl" Disabled 2>/dev/null || true
  else
    amixer -c "$CARD" -q sset "$ctl" 92% unmute 2>/dev/null || true
  fi
done

export AUDIODEV="plughw:${CARD},0"

if [ "$PERSONA" = "tars" ]; then
  VOICE="mb-us2"
  SPEED="145"
  PITCH="36"
  SOX_VOICE_FX="pitch -80 highpass 140 lowpass 3800 echo 0.85 0.75 10 0.12 gain -n -3.5"
  N1="392.00"; N2="493.88"; N3="587.33"; N_ALERT="659.25"
else
  VOICE="mb-us3"
  SPEED="152"
  PITCH="46"
  SOX_VOICE_FX="pitch -20 highpass 160 lowpass 4000 echo 0.85 0.75 8 0.10 gain -n -3.5"
  N1="523.25"; N2="659.25"; N3="783.99"; N_ALERT="880.00"
fi

if ! espeak-ng --voices=mb 2>/dev/null | grep -q "${VOICE#mb-}"; then
  VOICE="en-us"
fi

CALLER="${AG_CALLER:-}"
if [ -z "$CALLER" ]; then
  LOCAL_USER="$(whoami 2>/dev/null || true)"
  if [ -n "$LOCAL_USER" ] && [ "$LOCAL_USER" != "root" ] && [ -f /etc/ag-operator ]; then
    CALLER="$(tr -d '\r\n' < /etc/ag-operator)"
  else
    CALLER="${LOCAL_USER:-operator}"
  fi
fi

speak() {
  local text="$1"
  text="$(printf '%s' "$text" | sed -E \
    -e "s/\b(Mr\.?|Mister)[[:space:]]+Cooper\b/${CALLER}/gi" \
    -e "s/\b(Dr\.?|Doctor)[[:space:]]+Brand\b/${CALLER}/gi" \
    -e "s/\b(Cooper|Coop)\b/${CALLER}/gi" \
    -e "s/\\\$\(whoami\)|@whoami/${CALLER}/gi")"
  espeak-ng -a 150 -v "$VOICE" -s "$SPEED" -p "$PITCH" --stdout "$text" 2>/dev/null \
    | play -q -t wav - pad 0.20 0.30 $SOX_VOICE_FX 2>/dev/null || true
}

chime_up() {
  play -q -n synth 0.11 sine "$N1" : synth 0.05 sine 0 : synth 0.11 sine "$N2" : synth 0.05 sine 0 : synth 0.18 sine "$N3" pad 0.12 0.65 gain -3.5 2>/dev/null || true
}

chime_down() {
  play -q -n synth 0.11 sine "$N3" : synth 0.05 sine 0 : synth 0.11 sine "$N2" : synth 0.05 sine 0 : synth 0.20 sine "$N1" pad 0.45 0.25 gain -3.5 2>/dev/null || true
}

chime_alert() {
  play -q -n synth 0.12 sine "$N_ALERT" : synth 0.08 sine 0 : synth 0.16 sine "$N_ALERT" pad 0.12 0.65 gain -3.5 2>/dev/null || true
}

case "$EVENT" in
  online)
    chime_up
    sleep 0.45
    speak "${HOST}, online and ready."
    ;;
  offline)
    speak "${HOST}, entering standby."
    sleep 0.45
    chime_down
    ;;
  input)
    chime_alert
    sleep 0.45
    speak "${HOST}, waiting for user input. ${MSG}"
    ;;
  done)
    chime_up
    sleep 0.45
    speak "${HOST}, task complete. ${MSG}"
    ;;
  say|*)
    if [ -n "$MSG" ]; then
      speak "$MSG"
    else
      speak "$EVENT"
    fi
    ;;
esac
EOF
  sudo chmod +x /usr/local/bin/ag-notify

  sudo tee /etc/systemd/system/ag-audio-online.service >/dev/null <<'EOF'
[Unit]
Description=Antigravity Agent Mesh Audible Online Notification
After=multi-user.target sound.target

[Service]
Type=idle
ExecStart=/usr/local/bin/ag-notify online
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable ag-audio-online.service
else
  log "[6/9] Skipping chassis speaker TTS setup (--no-tts)."
fi

# ==============================================================================
# [7/9] Shared SSD Caches (/opt/mesh/cache), ag-acp-worker & ag-mesh-worktree
# ==============================================================================
log "[7/9] Configuring /opt/mesh/cache (${CCACHE_SIZE} ccache, -j${MAKE_JOBS}/socket), ag-acp-worker, and ag-mesh-worktree..."

mkdir -p /opt/mesh/cache/{ccache,buildroot-dl,cargo,npm,pip,xdg-cache} /opt/mesh/tools /opt/mesh/repos
for ((n=0; n<NUMA_NODES; n++)); do
  mkdir -p "/opt/mesh/workspaces/node${n}"
done

for pair in '.cache:xdg-cache' '.npm:npm'; do
  dot="${pair%%:*}"
  target="/opt/mesh/cache/${pair##*:}"
  if [ -d "${USER_HOME}/${dot}" ] && [ ! -L "${USER_HOME}/${dot}" ]; then
    cp -a "${USER_HOME}/${dot}/." "${target}/" 2>/dev/null || true
    rm -rf "${USER_HOME}/${dot}"
  fi
  ln -sfn "$target" "${USER_HOME}/${dot}"
done
ln -sfn /opt/mesh/tools "${USER_HOME}/tools"

if [ "$WITH_EDA" -eq 1 ] && [ ! -f /opt/mesh/tools/freerouting.jar ]; then
  curl -fsSL -L -o /opt/mesh/tools/freerouting.jar \
    "https://github.com/freerouting/freerouting/releases/download/v2.0.1/freerouting-2.0.1.jar" 2>/dev/null || true
fi

ccache --set-config=cache_dir=/opt/mesh/cache/ccache --set-config=max_size="$CCACHE_SIZE" --set-config=compression=true
CCACHE_DIR=/opt/mesh/cache/ccache ccache --set-config=cache_dir=/opt/mesh/cache/ccache --set-config=max_size="$CCACHE_SIZE" --set-config=compression=true
sudo chown -R "${TARGET_USER}:${TARGET_USER}" /opt/mesh "${USER_HOME}"
apt-mark showmanual | sort | sudo tee /etc/ag-baseline-packages.list >/dev/null
sudo chmod 0644 /etc/ag-baseline-packages.list

sudo tee /usr/local/bin/ag-acp-worker >/dev/null <<EOF
#!/usr/bin/env bash
# Generic ACP stdio worker entrypoint with NUMA pinning + shared SSD build caches
# Usage: ag-acp-worker <numa_node: 0|1|...|interleave> [workspace_subpath] [extra_agy_flags...]
set -euo pipefail
echo 0 > /run/ag-idle-minutes 2>/dev/null || true

NUMA_NODE="\${1:-0}"
SUBPATH="\${2:-node\${NUMA_NODE}}"
shift \$(( \$# >= 2 ? 2 : \$# ))

WORKSPACE_DIR="/opt/mesh/workspaces/\${SUBPATH}"
mkdir -p "\$WORKSPACE_DIR"
cd "\$WORKSPACE_DIR"

HOME_DIR="\${HOME:-\$(getent passwd "\$(id -un)" | cut -d: -f6)}"
export HOME="\$HOME_DIR"

SHARED_ENV=(
  HOME="\$HOME"
  PATH="/usr/lib/ccache:/opt/mesh/cache/cargo/bin:\${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  NO_COLOR=1
  TERM=dumb
  CCACHE_DIR="/opt/mesh/cache/ccache"
  CCACHE_BASEDIR="\$WORKSPACE_DIR"
  CCACHE_NOHASHDIR=1
  CCACHE_SLOPPINESS="file_macro,time_macros"
  BR2_DL_DIR="/opt/mesh/cache/buildroot-dl"
  CARGO_HOME="/opt/mesh/cache/cargo"
  npm_config_cache="/opt/mesh/cache/npm"
  PIP_CACHE_DIR="/opt/mesh/cache/pip"
  MAKEFLAGS="-j${MAKE_JOBS}"
  CMAKE_BUILD_PARALLEL_LEVEL="${MAKE_JOBS}"
)

if [ -x "\${HOME}/.local/bin/agy" ]; then
  exec /usr/local/bin/ag-numa-exec "\$NUMA_NODE" env "\${SHARED_ENV[@]}" "\${HOME}/.local/bin/agy" acp "\$@"
elif [ -x "\$HOME/.local/share/antigravity/agy_acp_server.par" ]; then
  exec /usr/local/bin/ag-numa-exec "\$NUMA_NODE" env "\${SHARED_ENV[@]}" "\$HOME/.local/share/antigravity/agy_acp_server.par" "\$@"
else
  exec /usr/local/bin/ag-numa-exec "\$NUMA_NODE" env "\${SHARED_ENV[@]}" agy acp "\$@"
fi
EOF
sudo chmod +x /usr/local/bin/ag-acp-worker

sudo tee /usr/local/bin/ag-mesh-worktree >/dev/null <<'EOF'
#!/usr/bin/env bash
# Generic Bare-Repo + Multi-NUMA Git Worktree Provisioner
# Usage: ag-mesh-worktree <project_name> [target_ref] [--preserve-untracked]
set -euo pipefail
echo 0 > /run/ag-idle-minutes 2>/dev/null || true

PROJECT="${1:?Usage: ag-mesh-worktree <project_name> [target_ref] [--preserve-untracked]}"
TARGET_REF="${2:-refs/heads/mesh-sync}"
PRESERVE="${3:-}"

BARE_REPO="/opt/mesh/repos/${PROJECT}.git"
HOST="$(hostname)"
NUMA_COUNT=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
[ "$NUMA_COUNT" -ge 1 ] || NUMA_COUNT=1

mkdir -p "/opt/mesh/repos"
for ((node=0; node<NUMA_COUNT; node++)); do
  mkdir -p "/opt/mesh/workspaces/node${node}"
done

if [ ! -d "$BARE_REPO" ]; then
  git init --bare --initial-branch=main "$BARE_REPO" >/dev/null
fi

cd "$BARE_REPO"
git update-ref -d refs/heads/HEAD 2>/dev/null || true
git worktree prune

if ! git rev-parse --verify --quiet "${TARGET_REF}^{commit}" >/dev/null; then
  echo "Error: target ref '$TARGET_REF' does not exist in $BARE_REPO yet (push a ref first)." >&2
  exit 1
fi

for ((node=0; node<NUMA_COUNT; node++)); do
  WT_DIR="/opt/mesh/workspaces/node${node}/${PROJECT}"
  BRANCH="mesh/${HOST}-node${node}"

  if ! git -C "$WT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rm -rf "$WT_DIR"
    git worktree add --quiet -f -B "$BRANCH" "$WT_DIR" "$TARGET_REF" >/dev/null
  else
    git -C "$WT_DIR" checkout -B "$BRANCH" "$TARGET_REF" --quiet
    git -C "$WT_DIR" reset --hard "$TARGET_REF" >/dev/null
    if [ "$PRESERVE" != "--preserve-untracked" ]; then
      git -C "$WT_DIR" clean -fd >/dev/null
    fi
  fi
  git -C "$WT_DIR" submodule update --init --recursive --quiet 2>/dev/null || true
  REV=$(git -C "$WT_DIR" rev-parse --short HEAD)
  printf "[%-10s | node%s] %s -> %s (%s)\n" "$HOST" "$node" "$BRANCH" "$WT_DIR" "$REV"
done
EOF
sudo chmod +x /usr/local/bin/ag-mesh-worktree

# ==============================================================================
# [8/9] Idle S5 Standby Watchdog (ag-idle-watchdog.timer + tmpfiles.d)
# ==============================================================================
if [ "$IDLE_LIMIT_MIN" -gt 0 ]; then
  log "[8/9] Installing ${IDLE_LIMIT_MIN}-minute idle S5 standby watchdog..."

  LOAD_THRESHOLD=$(( TOTAL_CPUS * 2 ))
  [ "$LOAD_THRESHOLD" -lt 25 ] && LOAD_THRESHOLD=25
  [ "$LOAD_THRESHOLD" -gt 100 ] && LOAD_THRESHOLD=100

  echo "f /run/ag-idle-minutes 0666 ${TARGET_USER} ${TARGET_USER} - 0" | sudo tee /etc/tmpfiles.d/ag-idle-watchdog.conf >/dev/null
  sudo systemd-tmpfiles --create /etc/tmpfiles.d/ag-idle-watchdog.conf

  sudo tee /usr/local/bin/ag-idle-watchdog >/dev/null <<EOF
#!/usr/bin/env bash
# Auto-poweroff into S5 standby after IDLE_LIMIT_MIN minutes of zero subagent/remote/interactive work
set -euo pipefail

IDLE_LIMIT_MIN="\${1:-${IDLE_LIMIT_MIN}}"
STATE_FILE="/run/ag-idle-minutes"
touch "\$STATE_FILE" && chown ${TARGET_USER}:${TARGET_USER} "\$STATE_FILE" && chmod 0666 "\$STATE_FILE" 2>/dev/null || true

# 1. Active cgroup tasks inside antigravity.slice
if grep -q '[0-9]' /sys/fs/cgroup/antigravity.slice/run-*.scope/cgroup.procs 2>/dev/null; then
  echo 0 > "\$STATE_FILE"
  exit 0
fi

# 2. Active ACP workers, compilers, Remote-SSH IDE servers, OR non-daemon agy CLI commands
if pgrep -f "ag-acp-worker|agy (acp|chat|run|agent)|agy_acp_server|\\.antigravity-server|\\.vscode-server|ccache|gcc|g\\+\\+|clang|cargo|rustc|ninja|make|pytest" >/dev/null 2>&1; then
  echo 0 > "\$STATE_FILE"
  exit 0
fi

# 3. Any interactive agy CLI process OR active child spawned by agy remote-control serve
for agy_pid in \$(pgrep -x "agy" 2>/dev/null || true); do
  cmd=\$(tr '\\0' ' ' < "/proc/\$agy_pid/cmdline" 2>/dev/null || true)
  if [[ "\$cmd" != *"remote-control serve"* ]]; then
    echo 0 > "\$STATE_FILE"
    exit 0
  elif [ -n "\$(pgrep -P "\$agy_pid" 2>/dev/null || true)" ]; then
    echo 0 > "\$STATE_FILE"
    exit 0
  fi
done

# 4. Interactive SSH PTY sessions (utmp)
if [ "\$(who | wc -l)" -gt 0 ]; then
  echo 0 > "\$STATE_FILE"
  exit 0
fi

# 5. Active SSH remote port-forwards or non-ControlMaster subshells
for sshd_pid in \$(pgrep -u ${TARGET_USER} -f "sshd" 2>/dev/null || true); do
  if [ -n "\$(pgrep -P "\$sshd_pid" 2>/dev/null || true)" ]; then
    echo 0 > "\$STATE_FILE"
    exit 0
  fi
done

# 6. Check 1-minute CPU load average
LOAD_INT=\$(awk '{printf "%d", \$1 * 100}' /proc/loadavg)
if [ "\$LOAD_INT" -ge ${LOAD_THRESHOLD} ]; then
  echo 0 > "\$STATE_FILE"
  exit 0
fi

COUNT=0
[ -f "\$STATE_FILE" ] && COUNT=\$(cat "\$STATE_FILE" 2>/dev/null || echo 0)
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "\$STATE_FILE"

if [ "\$COUNT" -ge "\$IDLE_LIMIT_MIN" ]; then
  logger -t ag-idle-watchdog "Node idle for \${COUNT}m (limit \${IDLE_LIMIT_MIN}m). Entering S5 WoL standby."
  if [ -x /usr/local/bin/ag-notify ]; then
    /usr/local/bin/ag-notify offline || true
  fi
  rm -f "\$STATE_FILE"
  systemctl poweroff
fi
EOF
  sudo chmod +x /usr/local/bin/ag-idle-watchdog

  sudo tee /etc/systemd/system/ag-idle-watchdog.service >/dev/null <<EOF
[Unit]
Description=Antigravity Cluster Idle S5 Powerdown Check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ag-idle-watchdog ${IDLE_LIMIT_MIN}
EOF

  sudo tee /etc/systemd/system/ag-idle-watchdog.timer >/dev/null <<'EOF'
[Unit]
Description=Run Antigravity Idle Watchdog every 60s

[Timer]
OnBootSec=5min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now ag-idle-watchdog.timer
else
  log "[8/9] Idle watchdog disabled (--idle-minutes 0)."
  sudo systemctl disable --now ag-idle-watchdog.timer 2>/dev/null || true
fi

# ==============================================================================
# [9/9] Antigravity 2.0 CLI (agy) & Remote Control Daemon
# ==============================================================================
log "[9/9] Installing/verifying Antigravity CLI (agy) and systemd user daemon..."

if [ ! -x "${USER_HOME}/.local/bin/agy" ]; then
  curl -fsSL https://antigravity.google/cli/install.sh | bash
else
  "${USER_HOME}/.local/bin/agy" update 2>/dev/null || true
fi

grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "${USER_HOME}/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${USER_HOME}/.bashrc"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "${USER_HOME}/.profile" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${USER_HOME}/.profile"
export PATH="${USER_HOME}/.local/bin:$PATH"
sudo ln -sf "${USER_HOME}/.local/bin/agy" /usr/local/bin/agy

sudo loginctl enable-linger "$TARGET_USER"

mkdir -p "${USER_HOME}/.config/systemd/user/antigravity-cli-daemon.service.d"
cat <<EOF > "${USER_HOME}/.config/systemd/user/antigravity-cli-daemon.service.d/mesh-limits.conf"
[Service]
WorkingDirectory=/opt/mesh/workspaces
Environment="PATH=${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config"

if systemctl --user list-unit-files antigravity-cli-daemon.service >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  systemctl --user restart antigravity-cli-daemon.service 2>/dev/null || true
fi

log "Provisioning complete on ${HOST_NAME}!"
printf "  - Storage: / (%s free), /opt/mesh (%s free)\n" \
  "$(df -h / | awk 'NR==2{print $4}')" "$(df -h /opt/mesh | awk 'NR==2{print $4}')"
printf "  - Governor: %s | Wake-on-LAN (%s): %s\n" \
  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')" \
  "$PRIMARY_NIC" \
  "$(sudo ethtool "$PRIMARY_NIC" 2>/dev/null | awk '/Supports Wake-on|Wake-on:/{printf "%s ", $0}' | tr -s ' ')"
printf "  - Workers: %s NUMA node(s), -j%s per socket, slice %s%% CPU / %sG RAM\n" \
  "$NUMA_NODES" "$MAKE_JOBS" "$CPU_QUOTA" "$MEM_MAX_GB"
