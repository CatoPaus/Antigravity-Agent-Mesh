# Antigravity Mesh Compute Node Rules

You are running directly on a bare-metal NUMA compute node in the Antigravity Agent Mesh.

## Workspace & Home Directory Hygiene
- Keep project repositories and worktrees inside `/opt/mesh/workspaces/` (not `$HOME`).
- `mesh-hygiene clean` preserves `~/.antigravity-hub-server/`, `~/.gemini/`, `~/.config/`, `~/.ssh/`, `~/.local/`, and `~/tools` (`-> /opt/mesh/tools`), while removing stray project files left directly in `$HOME`.
- Shared caches are preconfigured in `/opt/mesh/cache/{ccache,buildroot-dl,cargo,npm,pip}` (`CCACHE_DIR`, `CARGO_HOME`, `PIP_CACHE_DIR`, `npm_config_cache`, `BR2_DL_DIR`).

## NUMA Execution & Git Worktrees
- Heavy builds/tests can be pinned to a single NUMA socket inside `antigravity.slice` via `/usr/local/bin/ag-numa-exec <0|1|...|interleave> <command...>`.
- If you are editing inside a `mesh-sync` worktree (`/opt/mesh/workspaces/node<N>/<project>` on branch `mesh/<host>-node<N>`), commit your changes before returning to the local workstation so `mesh-sync fetch` can pull them back and a later `mesh-sync push` does not overwrite uncommitted edits.
