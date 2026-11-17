# Dell Precision T7610 — BIOS, `cctk` & NUMA Memory Guide

If your compute mesh nodes are dual-socket **Dell Precision T7610** workstations, tuning the BIOS ensures true per-socket NUMA memory locality, full Intel Turbo Boost headroom, and reliable headless Wake-on-LAN from S5 standby.

*(Note: `provision-node.sh` automatically detects Dell hardware via `/sys/class/dmi/id/sys_vendor` and applies all `cctk` tokens below over SSH. You can skip this on non-Dell servers with `--no-dell-bios`.)*

---

## 1. Memory Balancing (White-Tab vs. Black-Tab DIMM Slots)

On the Dell Precision T7610 motherboard:
- **White release levers (`DIMM1`–`DIMM4` per CPU)** are the **primary slots** for Channels A, B, C, and D on each socket. Always populate your largest DIMMs in `DIMM1`–`DIMM4` first.
- **Black release levers (`DIMM5`–`DIMM8` per CPU)** are the secondary slots (`DIMM5` pairs with `DIMM1`, `DIMM6` with `DIMM2`, etc.).
- **Symmetric 50/50 Rule:** Install the exact same DIMM sizes in `DIMM1..4_CPU1` and `DIMM1..4_CPU2` (for example, `2× 16 GB + 2× 8 GB = 48 GB` per socket → `96 GB` per workstation) so both NUMA nodes have identical capacity and 4-channel memory bandwidth.

---

## 2. Critical BIOS Settings (`F2` or `cctk`)

### Performance Menu
- **Multi Core Support (`--CpuCores=All`):** Enables all physical cores on both sockets.
- **Intel SpeedStep (`--Speedstep=Enabled`):** Exposes hardware P-states to Linux `intel_pstate`.
- **Intel HyperThreading (`--LogicProc=Enabled`):** Exposes all hardware threads.
- **Intel TurboBoost (`--TurboMode=Enabled`):** Enables full single/all-core Turbo bins.
- **Node Interleaving / NUMA (`--NodeInterleave=Enabled`):**
  > [!IMPORTANT]
  > Dell's Precision T7610 BIOS defines `NodeInterleave` **opposite to PowerEdge servers** (verified via `sudo cctk -H --NodeInterleave`):
  > - **`Enabled` (`NodeInterleave=Enabled`) = NUMA Mode Active (Correct):** Each CPU socket receives its own NUMA memory node (`numactl --hardware` reports `available: 2 nodes (0-1)`).
  > - **`Disabled` (`NodeInterleave=Disabled`) = SMP Interleaved Mode (Wrong):** Memory is interleaved across sockets (`available: 1 nodes (0)`).
- **C-States Control (`--CStatesCtrl=Enabled`):** Allows idle cores to sleep so active cores hit peak Turbo Boost multipliers.
- **Cache Prefetch (`--HwPrefetcher=Enabled`, `--AdjCachePrefetch=Enabled`):** Keep enabled.

### Power Management Menu
- **CPU Power Mode:** Set to **`Performance Per Watt (OS)`** (or `Maximum Performance`) so Linux controls P-states directly; `provision-node.sh` also enables `cpufreq-performance.service` to lock the governor to `performance`.
- **AC Recovery (`--AcPwrRcvry=Last`):** Restores prior power state after power events.
- **Deep Sleep Control (`--DeepSleepCtrl=Disabled`):**
  > [!WARNING]
  > If Deep Sleep is enabled, the Intel 82579LM NIC powers down in S5 and ignores Wake-on-LAN Magic Packets.
- **Wake on LAN (`--WakeOnLan=LanOnly`):** Wakes only on Magic Packets sent to the primary `Intel 82579LM` port (`NIC1` / `enp0s25`).

### System Configuration & Headless POST
- **Primary NIC (`--EmbNic1=Enabled`)** *(without PXE)* & **Secondary NIC (`--EmbNic2=Disabled`):** Plug Ethernet into the primary `82579LM` port and disable the secondary `82574L` NIC so it draws zero power and avoids DHCP/link-sense boot delays.
- **Storage (`--IntegratedSas=Enabled`, `--EmbSataRaid=Ahci`):** Powers the SATA/SAS backplane in AHCI mode. Disable unused optical/SATA ports (`--Sata4=Disabled`, `--Sata5=Disabled`) and unused COM1 UART (`--Serial1=Disabled`).
- **Audio (`--IntegratedAudio=Enabled`):** Enables the onboard Realtek HD Audio controller for the internal chassis speaker (`ag-notify`).
- **Headless POST (`--Fastboot=Minimal`, `--RptKeyErr=Disabled`, `--OromKeyboardAccess=Disabled`):** Prevents halting on `F1 to continue` when no keyboard or monitor is attached, and use **UEFI** boot with Legacy Option ROMs unchecked.

---

## 3. Applying & Auditing BIOS Settings Over SSH

`provision-node.sh` installs Dell Command | Configure (`/opt/dell/dcc/cctk`, symlinked to `/usr/local/bin/cctk`). You can inspect or reboot into BIOS anytime:

```bash
# Query key BIOS tokens without rebooting
sudo cctk --NodeInterleave --TurboMode --Speedstep --CStatesCtrl --WakeOnLan --DeepSleepCtrl --EmbNic2 --IntegratedAudio

# Reboot straight into the graphical BIOS setup screen (if a monitor/KVM is attached)
sudo systemctl reboot --firmware-setup
```
