# Step-by-Step Setup & Operations Manual

This manual covers setting up a multi-node NUMA compute mesh for **Google Antigravity 2.0**—from fresh Ubuntu Server installation through autonomous Lead Agent delegation.

---

## 1. Preconditions (Manual Steps)

### Precondition 1: Hardware Prep
1. **Balance RAM Across CPU Sockets (NUMA):** Populate identical DIMM capacities on every CPU socket so memory bandwidth and capacity split evenly across NUMA nodes (see [Dell T7610 BIOS & DIMM Guide](./DELL-T7610-BIOS.md) if using Dell Precision T7610 hardware).
2. **Storage Layout:**
   - **OS Drive (`/dev/sda`):** Ubuntu Server root filesystem.
   - **Optional Scratch SSD (`/dev/sdb`):** Dedicated `/opt/mesh` drive (`ext4`, `LABEL=mesh_scratch`) for bare Git repos, per-socket worktrees, and shared build caches. If `/dev/sdb` is absent, `/opt/mesh` falls back to the root filesystem cleanly.
3. **Network:** Connect Ethernet to your Wake-on-LAN-capable primary NIC and assign static DHCP reservations in your router/gateway.

### Precondition 2: Fresh Ubuntu Server + Passwordless SSH
1. Install **Ubuntu Server LTS** (24.04 or 26.04) in UEFI mode with **OpenSSH server** enabled, using a consistent worker username (e.g., `ag-worker`).
2. From your primary workstation (Linux or WSL), copy your SSH public key and enable passwordless `sudo`:
   ```bash
   [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

   ssh-copy-id ag-worker@192.168.1.210
   ssh-copy-id ag-worker@192.168.1.211

   for ip in 192.168.1.210 192.168.1.211; do
     ssh -t "ag-worker@${ip}" "echo 'ag-worker ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-ag-worker && sudo chmod 0440 /etc/sudoers.d/90-ag-worker"
   done
   ```

---

## 2. Automated Provisioning (`bootstrap-mesh.sh`)

[`bootstrap-mesh.sh`](../bootstrap-mesh.sh) configures your local control plane (`~/.config/mesh/cluster.conf`, `~/.ssh/config`, `/usr/local/bin/mesh-*`, `settings.json` `.acpServers`, and global Antigravity rules) and streams [`provision-node.sh`](../provision-node.sh) to all configured nodes in parallel.

```bash
cd Antigravity-Agent-Mesh
chmod +x bootstrap-mesh.sh provision-node.sh bin/* scripts/*

./bootstrap-mesh.sh \
  --node node1=192.168.1.210,,tars \
  --node node2=192.168.1.211,,case \
  --user ag-worker \
  --provision-nodes --sync-auth --reboot-nodes --verify
```

*(Leaving the MAC field empty between the two commas—`alias=ip,,persona`—tells `bootstrap-mesh.sh` to auto-discover the live MAC address over SSH. You can also pass an explicit MAC like `node1=192.168.1.210,aa:bb:cc:dd:ee:ff,tars`.)*

### Optional Flags
- `--with-eda` — Installs KiCad 10 PPA, headless JRE, and `/opt/mesh/tools/freerouting.jar`.
- `--with-embedded` — Installs `gcc-arm-none-eabi`, `libnewlib-arm-none-eabi`, and `libstdc++-arm-none-eabi-newlib`.
- `--no-tts` — Skips ALSA, SoX, `espeak-ng`, and MBROLA speaker setup.
- `--no-dell-bios` / `--dell-bios` — Overrides automatic Dell DMI detection for `cctk` BIOS tuning.
- `--idle-minutes <N>` — Sets idle timeout before S5 poweroff (`30` default; `0` disables `ag-idle-watchdog.timer`).
- `--ccache-size <size>` — Sets shared `ccache` limit (`25.0G` default).
- `--control-plane-only` — Updates local `/usr/local/bin/mesh-*`, `~/.config/mesh/cluster.conf`, and rules without touching remote nodes.

### Authenticating `agy` on Nodes
If you did not use `--sync-auth` (or need fresh headless credentials), authenticate once per node:
```bash
ssh -t node1 "~/.local/bin/agy acp --login"
ssh -t node2 "~/.local/bin/agy acp --login"
```

---

## 3. Using the Mesh in Antigravity 2.0

### Desktop App Settings Check
In the Antigravity 2.0 left-hand sidebar under **Settings**:
1. **Skills & Customizations → Rules:** Confirm `mesh-cluster.md` (`GEMINI.md`) is active.
2. **Tool Execution Policy:** Set to `always-proceed` or allowlist `wsl -d Ubuntu*`, `/usr/local/bin/mesh-*`, and `git *` so the Lead Agent can dispatch multi-socket jobs uninterrupted.

### Example Chat Canvas Prompts
- **4-Socket Sweep:** *"Sync this repo to the mesh and run the full test suite across all sockets in parallel."*
- **Asymmetric Split:** *"Sync this repo to the mesh. Build release targets on `node2-node0` and `node2-node1`, run tests on `node1-node0`, and run a static audit on `node1-node1`. Fetch any fixes back."*
- **Iterative Debug (`--continue`):** *"Send the failing build to `node2-node0` and iterate using `mesh-acp --continue` until tests pass, then merge the branch back."*
- **Hygiene & Sleep:** *"Run `mesh-hygiene status`, clean any stray files, announce completion, and put the cluster into S5 sleep."*

---

## 4. Direct CLI Reference

```bash
# List available socket targets from ~/.config/mesh/cluster.conf
mesh-acp --list-targets

# Run one prompt across every NUMA socket (auto-wake + push + fetch)
mesh-acp all "Run pytest and report failures." --model gemini-4-argon-medium --sync --keep-build --fetch --skip-perms

# Asymmetric parallel fan-out
mesh-sync push --keep-build
mesh-acp node2-node0 "Compile release binary" --model gemini-4-argon-high --skip-perms --no-stream &
mesh-acp node1-node0 "Run integration tests"  --model gemini-4-argon-medium --skip-perms --no-stream &
wait
mesh-sync fetch

# Multi-turn resume on a single socket
mesh-acp node2-node0 "Now run benchmarks on the binary." --continue --skip-perms

# Inspect and merge remote commits
git diff HEAD..mesh/node2-node0
git merge mesh/node2-node0

# Power, sleep, and wake testing
mesh-power status
mesh-power wake
mesh-power sleep
./scripts/test-sleep-wake.sh

# Cluster storage, $HOME, and package parity hygiene
mesh-sync list
mesh-sync drop <project_name>
mesh-hygiene status
mesh-hygiene clean
mesh-hygiene freeze-packages
mesh-hygiene reset-packages
```

---

## 5. Subagent Model Selection Guide

| Model ID (`--model`) | Tier | Best Workload |
| :--- | :--- | :--- |
| **`gemini-4-argon-high`** | Deep Systems & Architecture | Complex C/C++/Rust/embedded code, architecture, multi-file refactors, root-cause debugging |
| **`gemini-4-argon-medium`** | Cluster Default | Standard implementation, test suites, `ASan`/`UBSan` triage, code audits |
| **`gemini-4-argon-low`** | Fast Structured Edits | Mechanical refactors and straightforward edits with low thinking latency |
| **`gemini-3.8-flash-high/medium/low`** | High-Speed Sweeps | Parallel codebase sweeps, log triage, boilerplate, and quick health probes |

---

## 6. Offline Chassis Speaker TTS (`ag-notify`)

Adapted from [primantah/tars](https://github.com/primantah/tars), `/usr/local/bin/ag-notify` pairs **MBROLA** (`espeak-ng` + `mbrola-us2` / `mbrola-us3`) with a **SoX** radio-comms bandpass/echo filter chain routed to the onboard speaker (`card 0: PCH`).

### Personas
- **`tars` Persona:** `mb-us2`, `145 wpm`, pitch `36`, **G Major** triad (`392.00 / 493.88 / 587.33 Hz`), E5 alert (`659.25 Hz`).
- **`case` Persona:** `mb-us3`, `152 wpm`, pitch `46`, **C Major** triad (`523.25 / 659.25 / 783.99 Hz`), A5 alert (`880.00 Hz`).

### Automatic `$(whoami)` Operator Binding
`mesh-power` passes `AG_CALLER="$(whoami)"` automatically (falling back to `/etc/ag-operator`). Inside `ag-notify`, occurrences of `$(whoami)`, `@whoami`, `Mr Cooper`, `Cooper`, `Coop`, or `Dr Brand` resolve to your operator username:

```bash
mesh-power say "All here, Mr Cooper. Confirmed. Additional customization?"
mesh-power notify done "It is what we intended, Dr Brand. One hundred percent."
mesh-power notify input "It needs a person to unlock its archival function, Coop."
AG_CALLER="Commander" mesh-power say "Ready. Fire. Detach."
```
