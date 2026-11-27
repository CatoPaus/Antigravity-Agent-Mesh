# Antigravity NUMA Compute Mesh

You have direct CLI access to a multi-socket bare-metal compute cluster via `/usr/local/bin/mesh-acp`, `/usr/local/bin/mesh-sync`, `/usr/local/bin/mesh-power`, and `/usr/local/bin/mesh-hygiene` (in WSL; from Windows PowerShell prefix with `wsl -d Ubuntu --cd ~ --`). Both `mesh-sync` and `mesh-acp` automatically wake the cluster from S5 standby via `mesh-power ensure` if asleep.

> **Preconditions & Governance:** Only invoke `mesh-*` commands when `~/.config/mesh/cluster.conf` and `/usr/local/bin/mesh-acp` exist on this host and the cluster subnet is reachable; on unconfigured or off-LAN machines, execute locally without attempting cluster calls. When global subagent delegation rules (`GEMINI.md`) are active, invoke `mesh-sync` and `mesh-acp` from delegated engineering subagents rather than directly in the primary supervisor context, and reserve cluster offload for heavy builds, multi-socket test/audit sweeps, or explicit user requests.

## Cluster Topology
{{CLUSTER_TOPOLOGY}}
- **Worktrees:** Each NUMA socket operates in an isolated Git worktree (`/opt/mesh/workspaces/node<N>/<project>`) backed by a single bare repo (`/opt/mesh/repos/<project>.git`) per server on branch `mesh/<host>-node<N>`.
- **Shared Caches:** `/opt/mesh/cache/{ccache,buildroot-dl,cargo,npm,pip}` is active on all sockets with `CCACHE_BASEDIR` + `CCACHE_NOHASHDIR=1` cross-worktree normalization (`100%` object cache hits across NUMA nodes).

## Subagent Model Selection (`mesh-acp --model <modelId>`)
Select the optimal model for every delegated task based on complexity:
- `gemini-4-argon-high` (**Gemini 4 Argon High**): Complex systems programming (C/C++/Rust/embedded), architectural design, multi-file refactoring, and deep root-cause debugging.
- `gemini-4-argon-medium` (**Gemini 4 Argon Medium**, cluster default): Standard feature implementation, build/test fixing, code audits, and general engineering tasks.
- `gemini-4-argon-low` (**Gemini 4 Argon Low**): Straightforward code edits and structured transformations with minimal thinking latency.
- `gemini-3.8-flash-high` / `gemini-3.8-flash-medium` / `gemini-3.8-flash-low` (**Gemini 3.8 Flash**): Fast parallel codebase sweeps, log/branch triage, boilerplate generation, and lightweight verification.

## Standard Orchestration Patterns
1. **Identical Prompt Across All Sockets (Auto-Sync + Auto-Fetch):**
   ```bash
   mesh-acp all "<prompt>" --model gemini-4-argon-high --sync --keep-build --fetch --skip-perms
   ```
2. **Parallel Asymmetric Task Split (Run `mesh-acp --list-targets` to see available sockets):**
   ```bash
   mesh-sync push --keep-build --target {{SAMPLE_TARGET}}
   mesh-acp {{SAMPLE_TARGET}} "<heavy build task>" --model gemini-4-argon-high --skip-perms --no-stream &
   # dispatch additional sockets in parallel (use --target <spec> to avoid resetting busy sibling sockets)...
   wait
   mesh-sync fetch --target {{SAMPLE_TARGET}}
   ```
3. **Inspecting & Merging Subagent Commits Locally:**
   After `mesh-sync fetch`, subagent branches are available locally at `refs/remotes/mesh/<target>`:
   - Diff: `git diff HEAD..mesh/{{SAMPLE_TARGET}}`
   - Cherry-pick / Merge: `git cherry-pick mesh/{{SAMPLE_TARGET}}` or `git merge mesh/{{SAMPLE_TARGET}}`
4. **Power Management & Audio Notifications:**
   - Check status: `mesh-power status`
   - Ensure awake: `mesh-power ensure`
   - Broadcast chassis speaker TTS/chime (when enabled): `mesh-power notify done "Build complete"` or `mesh-power say "Tests passed"`
   - Put cluster to S5 sleep when idle: `mesh-power sleep`
5. **Workspace, Package & Storage Hygiene (`mesh-sync` & `mesh-hygiene`):**
   - Never write ad-hoc project files or scripts directly into `/home/{{MESH_USER}}/`; keep all project work inside `/opt/mesh/workspaces/node<N>/<project>` and shared tools in `/opt/mesh/tools`.
   - List active projects and worktree disk usage on the cluster: `mesh-sync list`
   - Purge a dropped or temporary project from all servers (preserves `/opt/mesh/cache/ccache`): `mesh-sync drop <project_name>`
   - Audit or clean `$HOME` stray files, APT package drift (`/etc/ag-baseline-packages.list`), and caches: `mesh-hygiene status` | `mesh-hygiene clean` | `mesh-hygiene reset-packages` | `mesh-hygiene freeze-packages`
