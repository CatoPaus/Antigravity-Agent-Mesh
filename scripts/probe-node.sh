#!/usr/bin/env bash
# probe-node.sh: Hardware, NUMA, Storage, PCIe & Network Discovery Probe
set -euo pipefail

echo "## Node Overview: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "- **OS / Kernel:** $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2) / $(uname -r)"
echo "- **BIOS Version:** $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo 'Unknown') ($(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo 'n/a'))"
echo ""
echo "### 1. CPU & NUMA Topology"
lscpu | grep -E "Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|^CPU\(s\)|NUMA node" || true
echo ""
echo "### 2. Memory & NUMA Node Split"
free -h
grep -H . /sys/devices/system/node/node*/meminfo 2>/dev/null | grep -E "MemTotal|MemFree" || true
echo ""
echo "### 3. Storage & Partition Layout"
lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS,TRAN
echo ""
echo "### 4. PCIe Devices (GPUs, NVMe, SAS, NICs)"
lspci | grep -iE "vga|3d|display|nvme|Non-Volatile|sas|lsi|raid|ethernet|network" || true
echo ""
echo "### 5. Network Interfaces"
ip -br addr show
