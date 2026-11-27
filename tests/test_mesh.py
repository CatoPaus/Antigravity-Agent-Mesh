#!/usr/bin/env python3
"""Hermetic regression test suite for Antigravity Agent Mesh."""
import glob
import hashlib
import json
import os
import py_compile
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def extract_provision_heredoc(binary_name: str) -> str:
    prov_path = os.path.join(REPO_ROOT, "provision-node.sh")
    with open(prov_path, "r", encoding="utf-8") as f:
        src = f.read()

    m_quoted = re.search(
        rf"sudo tee /usr/local/bin/{re.escape(binary_name)} >/dev/null <<'EOF'\n(.*?)\nEOF",
        src,
        re.S,
    )
    if m_quoted:
        return m_quoted.group(1) + "\n"

    m_unquoted = re.search(
        rf"sudo tee /usr/local/bin/{re.escape(binary_name)} >/dev/null <<EOF\n(.*?)\nEOF",
        src,
        re.S,
    )
    if not m_unquoted:
        raise AssertionError(f"Could not find heredoc for {binary_name} in provision-node.sh")

    body = m_unquoted.group(1)
    # Simulate bash unquoted heredoc expansion with sample provisioning variables
    body = body.replace("${MAKE_JOBS}", "14")
    body = body.replace("${IDLE_LIMIT_MIN}", "30")
    body = body.replace("${TARGET_USER}", "ag-worker")
    body = body.replace("${USER_HOME}", "/home/ag-worker")
    body = body.replace("${LOAD_THRESHOLD}", "64")
    body = body.replace(r"\$", "$").replace(r"\\", "\\")
    return body + "\n"


class TestMeshSyntaxAndUnconfiguredCLI(unittest.TestCase):
    def test_bash_and_python_syntax(self):
        bash_scripts = [
            "bootstrap-mesh.sh",
            "provision-node.sh",
            "bin/mesh-sync",
            "bin/mesh-power",
            "bin/mesh-hygiene",
            "scripts/probe-node.sh",
            "scripts/test-sleep-wake.sh",
        ]
        for rel in bash_scripts:
            p = subprocess.run(
                ["bash", "-n", os.path.join(REPO_ROOT, rel)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(p.returncode, 0, f"bash -n failed for {rel}: {p.stderr}")

        for embedded in ("ag-numa-exec", "ag-notify", "ag-acp-worker", "ag-mesh-worktree", "ag-idle-watchdog"):
            script_text = extract_provision_heredoc(embedded)
            p = subprocess.run(["bash", "-n"], input=script_text, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, f"bash -n failed for embedded {embedded}: {p.stderr}")

        py_compile.compile(os.path.join(REPO_ROOT, "bin", "mesh-acp"), doraise=True)

    def test_unconfigured_cli_help_and_errors(self):
        scripts = [
            "bin/mesh-sync",
            "bin/mesh-power",
            "bin/mesh-hygiene",
            "scripts/test-sleep-wake.sh",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ)
            env["HOME"] = tmp
            env["MESH_CONFIG"] = os.path.join(tmp, "nonexistent-cluster.conf")

            for rel in scripts:
                full = os.path.join(REPO_ROOT, rel)
                help_proc = subprocess.run(["bash", full, "--help"], env=env, capture_output=True, text=True)
                self.assertEqual(help_proc.returncode, 0, f"{rel} --help failed: {help_proc.stderr}")
                self.assertNotIn("unbound variable", help_proc.stderr)

                err_proc = subprocess.run(["bash", full], env=env, capture_output=True, text=True)
                self.assertEqual(err_proc.returncode, 1, f"{rel} should exit 1 without config")
                self.assertIn("No nodes configured", err_proc.stderr)
                self.assertNotIn("unbound variable", err_proc.stderr)


class TestMeshACP(unittest.TestCase):
    def setUp(self):
        self.tmp_obj = tempfile.TemporaryDirectory()
        self.tmp = self.tmp_obj.name
        self.mock_bin = os.path.join(self.tmp, "mock_bin")
        self.cache_dir = os.path.join(self.tmp, "xdg_cache")
        self.log_file = os.path.join(self.tmp, "invocations.jsonl")
        self.conf_file = os.path.join(self.tmp, "cluster.conf")
        os.makedirs(self.mock_bin, exist_ok=True)

        with open(self.conf_file, "w", encoding="utf-8") as f:
            f.write(
                textwrap.dedent(
                    """\
                    MESH_USER="ag-worker"
                    MESH_NODES=(
                      "node1|192.168.1.210|00:11:22:33:44:10|2|tars|Worker 1"
                      "node2|192.168.1.211|00:11:22:33:44:20|2|case|Worker 2"
                    )
                    """
                )
            )

        self._write_executable(
            "mesh-power",
            f"""#!/usr/bin/env python3
import json, sys
with open({self.log_file!r}, "a", encoding="utf-8") as f:
    f.write(json.dumps({{"tool": "mesh-power", "argv": sys.argv[1:]}}) + "\\n")
""",
        )
        self._write_executable(
            "mesh-sync",
            f"""#!/usr/bin/env python3
import json, sys
with open({self.log_file!r}, "a", encoding="utf-8") as f:
    f.write(json.dumps({{"tool": "mesh-sync", "argv": sys.argv[1:]}}) + "\\n")
""",
        )
        self._write_executable(
            "ssh",
            f"""#!/usr/bin/env python3
import json, os, sys

mode = os.environ.get("MOCK_SSH_MODE", "ok")
with open({self.log_file!r}, "a", encoding="utf-8") as logf:
    logf.write(json.dumps({{"tool": "ssh", "argv": sys.argv[1:]}}) + "\\n")

counter = 0
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    msg = json.loads(raw)
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params", {{}})

    if method == "initialize":
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": mid, "result": {{"protocolVersion": 1}}}}) + "\\n")
        sys.stdout.flush()
    elif method == "session/resume":
        sid = params["sessionId"]
        with open({self.log_file!r}, "a", encoding="utf-8") as logf:
            logf.write(json.dumps({{"tool": "acp_resume", "sessionId": sid, "cwd": params.get("cwd")}}) + "\\n")
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": mid, "result": {{"sessionId": sid}}}}) + "\\n")
        sys.stdout.flush()
    elif method == "session/new":
        counter += 1
        cwd = params.get("cwd", "")
        sid = "sess-" + os.path.basename(cwd) + f"-{{os.getpid()}}"
        with open({self.log_file!r}, "a", encoding="utf-8") as logf:
            logf.write(json.dumps({{"tool": "acp_new", "sessionId": sid, "cwd": cwd}}) + "\\n")
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": mid, "result": {{"sessionId": sid}}}}) + "\\n")
        sys.stdout.flush()
    elif method in ("session/set_mode", "session/set_model"):
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": mid, "result": {{}}}}) + "\\n")
        sys.stdout.flush()
    elif method == "session/prompt":
        if mode == "stderr_flood":
            # Emit 192 KiB (> 64 KiB pipe buffer) on stderr before responding on stdout
            chunk = ("W" * 1023 + "\\n")
            for _ in range(192):
                sys.stderr.write(chunk)
            sys.stderr.flush()
        sys.stdout.write(json.dumps({{
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {{"update": {{"sessionUpdate": "agent_message_chunk", "content": {{"text": "Hello from mock worker!"}}}}}},
        }}) + "\\n")
        sys.stdout.flush()
        if mode == "oom_crash":
            sys.stderr.write("Killed by cgroup MemoryMax (OOM)\\n")
            sys.stderr.flush()
            os._exit(137)
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": mid, "result": {{"stopReason": "end_turn"}}}}) + "\\n")
        sys.stdout.flush()
""",
        )

    def tearDown(self):
        self.tmp_obj.cleanup()

    def _write_executable(self, name: str, content: str):
        p = os.path.join(self.mock_bin, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(p, 0o755)

    def _run_acp(self, args: list[str], mode: str = "ok", timeout: float = 10.0) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.mock_bin}:{env.get('PATH', '')}"
        env["MESH_CONFIG"] = self.conf_file
        env["XDG_CACHE_HOME"] = self.cache_dir
        env["MOCK_SSH_MODE"] = mode
        return subprocess.run(
            [sys.executable, os.path.join(REPO_ROOT, "bin", "mesh-acp"), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def _read_logs(self) -> list[dict]:
        if not os.path.exists(self.log_file):
            return []
        with open(self.log_file, "r", encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_success_and_target_scoped_sync_fetch(self):
        p = self._run_acp(
            ["node1-node0", "Run unit suite", "--sync", "--keep-build", "--fetch", "--skip-perms", "--no-stream"]
        )
        self.assertEqual(p.returncode, 0, f"mesh-acp failed: {p.stderr}")
        self.assertIn("Hello from mock worker!", p.stdout)

        logs = self._read_logs()
        power_calls = [x["argv"] for x in logs if x["tool"] == "mesh-power"]
        sync_calls = [x["argv"] for x in logs if x["tool"] == "mesh-sync"]
        self.assertEqual(power_calls, [["ensure", "node1"]])
        self.assertEqual(
            sync_calls,
            [
                ["push", "--target", "node1-node0", "--keep-build"],
                ["fetch", "--target", "node1-node0"],
            ],
        )

    def test_mid_prompt_oom_crash_returns_nonzero_and_skips_fetch(self):
        p = self._run_acp(["node2-node1", "Compile firmware", "--fetch", "--no-stream"], mode="oom_crash")
        self.assertEqual(p.returncode, 1)
        self.assertIn("Unexpected EOF before session/prompt response", p.stderr)
        self.assertIn("137", p.stderr)
        self.assertIn("Killed by cgroup MemoryMax", p.stderr)

        logs = self._read_logs()
        sync_calls = [x["argv"] for x in logs if x["tool"] == "mesh-sync"]
        self.assertEqual(sync_calls, [], "mesh-sync fetch must NOT run when worker crashes mid-prompt")

    def test_large_stderr_flood_no_deadlock(self):
        p = self._run_acp(["node1-node1", "Verbose build", "--no-stream"], mode="stderr_flood", timeout=10.0)
        self.assertEqual(p.returncode, 0, f"stderr flood failed: {p.stderr}")
        self.assertIn("Hello from mock worker!", p.stdout)

    def test_scoped_session_cache_isolated_by_cwd(self):
        p1 = self._run_acp(["node1-node0", "Init A", "--subpath", "projA", "--no-stream"])
        p2 = self._run_acp(["node1-node0", "Init B", "--subpath", "projB", "--no-stream"])
        self.assertEqual(p1.returncode, 0)
        self.assertEqual(p2.returncode, 0)

        sess_dir = os.path.join(self.cache_dir, "mesh", "sessions")
        self.assertEqual(stat.S_IMODE(os.stat(sess_dir).st_mode), 0o700)
        files = sorted(os.listdir(sess_dir))
        self.assertEqual(len(files), 2)
        for fn in files:
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(sess_dir, fn)).st_mode), 0o600)

        p1_cont = self._run_acp(["node1-node0", "Cont A", "--subpath", "projA", "--continue", "--no-stream"])
        p2_cont = self._run_acp(["node1-node0", "Cont B", "--subpath", "projB", "--continue", "--no-stream"])
        self.assertEqual(p1_cont.returncode, 0)
        self.assertEqual(p2_cont.returncode, 0)

        logs = self._read_logs()
        new_map = {x["cwd"]: x["sessionId"] for x in logs if x["tool"] == "acp_new"}
        resumes = [(x["cwd"], x["sessionId"]) for x in logs if x["tool"] == "acp_resume"]
        self.assertNotEqual(new_map["/opt/mesh/workspaces/node0/projA"], new_map["/opt/mesh/workspaces/node0/projB"])
        self.assertEqual(
            resumes,
            [
                ("/opt/mesh/workspaces/node0/projA", new_map["/opt/mesh/workspaces/node0/projA"]),
                ("/opt/mesh/workspaces/node0/projB", new_map["/opt/mesh/workspaces/node0/projB"]),
            ],
        )


class TestMeshSyncAndProvisionHelpers(unittest.TestCase):
    def _git_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env.update(
            {
                "GIT_AUTHOR_NAME": "Mesh Tester",
                "GIT_AUTHOR_EMAIL": "tester@example.com",
                "GIT_COMMITTER_NAME": "Mesh Tester",
                "GIT_COMMITTER_EMAIL": "tester@example.com",
            }
        )
        return env

    def test_dirty_snapshot_preserves_index_and_worktree(self):
        env = self._git_env()
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-b", "main", tmp], env=env, check=True, capture_output=True)
            with open(os.path.join(tmp, "staged.txt"), "w", encoding="utf-8") as f:
                f.write("v1-staged\n")
            with open(os.path.join(tmp, "unstaged.txt"), "w", encoding="utf-8") as f:
                f.write("v1-unstaged\n")
            subprocess.run(["git", "-C", tmp, "add", "."], env=env, check=True)
            subprocess.run(["git", "-C", tmp, "commit", "-m", "initial"], env=env, check=True, capture_output=True)

            # Mutate staged, unstaged, and untracked state
            with open(os.path.join(tmp, "staged.txt"), "w", encoding="utf-8") as f:
                f.write("v2-staged\n")
            subprocess.run(["git", "-C", tmp, "add", "staged.txt"], env=env, check=True)
            with open(os.path.join(tmp, "unstaged.txt"), "w", encoding="utf-8") as f:
                f.write("v2-unstaged\n")
            with open(os.path.join(tmp, "untracked.txt"), "w", encoding="utf-8") as f:
                f.write("brand-new-file\n")

            status_before = subprocess.check_output(
                ["git", "--no-optional-locks", "-C", tmp, "status", "--porcelain"], text=True
            )
            stage_before = subprocess.check_output(["git", "-C", tmp, "ls-files", "--stage"], text=True)
            index_path = os.path.join(tmp, ".git", "index")
            with open(index_path, "rb") as f:
                index_before = hashlib.sha256(f.read()).hexdigest()
            head_before = subprocess.check_output(["git", "-C", tmp, "rev-parse", "HEAD"], text=True).strip()
            tmp_indices_before = set(glob.glob("/tmp/mesh-sync-index.*"))

            sync_script = os.path.join(REPO_ROOT, "bin", "mesh-sync")
            snap_oid = subprocess.check_output(
                [
                    "bash",
                    "-c",
                    f'MESH_SYNC_SOURCE_ONLY=1 source "{sync_script}" && create_working_snapshot',
                ],
                cwd=tmp,
                env=env,
                text=True,
            ).strip()

            self.assertNotEqual(snap_oid, head_before)
            with open(index_path, "rb") as f:
                index_after = hashlib.sha256(f.read()).hexdigest()
            stage_after = subprocess.check_output(["git", "-C", tmp, "ls-files", "--stage"], text=True)
            status_after = subprocess.check_output(
                ["git", "--no-optional-locks", "-C", tmp, "status", "--porcelain"], text=True
            )
            head_after = subprocess.check_output(["git", "-C", tmp, "rev-parse", "HEAD"], text=True).strip()

            self.assertEqual(index_before, index_after, "Local .git/index bytes must not be mutated")
            self.assertEqual(stage_before, stage_after, "Local staged entries must not be mutated")
            self.assertEqual(status_before, status_after, "Working tree porcelain status must not change")
            self.assertEqual(head_before, head_after)
            self.assertEqual(set(glob.glob("/tmp/mesh-sync-index.*")) - tmp_indices_before, set())

            self.assertEqual(
                subprocess.check_output(["git", "-C", tmp, "show", f"{snap_oid}:staged.txt"], text=True),
                "v2-staged\n",
            )
            self.assertEqual(
                subprocess.check_output(["git", "-C", tmp, "show", f"{snap_oid}:unstaged.txt"], text=True),
                "v2-unstaged\n",
            )
            self.assertEqual(
                subprocess.check_output(["git", "-C", tmp, "show", f"{snap_oid}:untracked.txt"], text=True),
                "brand-new-file\n",
            )

    def test_ag_mesh_worktree_selective_nodes_and_busy_guard(self):
        env = self._git_env()
        wt_script_content = extract_provision_heredoc("ag-mesh-worktree")
        with tempfile.TemporaryDirectory() as tmp:
            wt_bin = os.path.join(tmp, "ag-mesh-worktree")
            with open(wt_bin, "w", encoding="utf-8") as f:
                f.write(wt_script_content)
            os.chmod(wt_bin, 0o755)

            src_repo = os.path.join(tmp, "src")
            mesh_root = os.path.join(tmp, "mesh")
            bare_repo = os.path.join(mesh_root, "repos", "demo.git")
            os.makedirs(os.path.dirname(bare_repo), exist_ok=True)
            subprocess.run(["git", "init", "--bare", "--initial-branch=main", bare_repo], env=env, check=True, capture_output=True)
            subprocess.run(["git", "init", "-b", "main", src_repo], env=env, check=True, capture_output=True)

            with open(os.path.join(src_repo, "ver.txt"), "w", encoding="utf-8") as f:
                f.write("v1\n")
            subprocess.run(["git", "-C", src_repo, "add", "ver.txt"], env=env, check=True)
            subprocess.run(["git", "-C", src_repo, "commit", "-m", "v1"], env=env, check=True, capture_output=True)
            subprocess.run(["git", "-C", src_repo, "push", bare_repo, "HEAD:refs/heads/mesh-sync"], env=env, check=True, capture_output=True)

            wt_env = dict(env)
            wt_env["AG_MESH_ROOT"] = mesh_root
            wt_env["AG_NUMA_COUNT"] = "2"

            # Initialize both node0 and node1 at v1
            subprocess.run(["bash", wt_bin, "demo", "refs/heads/mesh-sync"], env=wt_env, check=True, capture_output=True)

            # Advance mesh-sync to v2, but update ONLY --nodes 0
            with open(os.path.join(src_repo, "ver.txt"), "w", encoding="utf-8") as f:
                f.write("v2\n")
            subprocess.run(["git", "-C", src_repo, "commit", "-am", "v2"], env=env, check=True, capture_output=True)
            subprocess.run(["git", "-C", src_repo, "push", "-f", bare_repo, "HEAD:refs/heads/mesh-sync"], env=env, check=True, capture_output=True)

            subprocess.run(["bash", wt_bin, "demo", "refs/heads/mesh-sync", "--nodes", "0"], env=wt_env, check=True, capture_output=True)

            node0_dir = os.path.join(mesh_root, "workspaces", "node0", "demo")
            node1_dir = os.path.join(mesh_root, "workspaces", "node1", "demo")
            with open(os.path.join(node0_dir, "ver.txt"), "r", encoding="utf-8") as f:
                self.assertEqual(f.read(), "v2\n")
            with open(os.path.join(node1_dir, "ver.txt"), "r", encoding="utf-8") as f:
                self.assertEqual(f.read(), "v1\n", "Sibling socket node1 must remain untouched")

            # Simulate an active build/worker process running inside node0_dir
            dirty_marker = os.path.join(node0_dir, "in_progress.c")
            with open(dirty_marker, "w", encoding="utf-8") as f:
                f.write("int active = 1;\n")

            busy_proc = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                cwd=node0_dir,
            )
            try:
                time.sleep(0.05)
                blocked = subprocess.run(
                    ["bash", wt_bin, "demo", "refs/heads/mesh-sync", "--nodes", "0"],
                    env=wt_env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(blocked.returncode, 1)
                self.assertIn("Refusing to reset busy worktree", blocked.stderr)
                self.assertTrue(os.path.exists(dirty_marker), "Busy worktree dirty file must not be wiped")

                forced = subprocess.run(
                    ["bash", wt_bin, "demo", "refs/heads/mesh-sync", "--nodes", "0", "--force"],
                    env=wt_env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(forced.returncode, 0, f"--force should succeed: {forced.stderr}")
                self.assertFalse(os.path.exists(dirty_marker))
            finally:
                busy_proc.terminate()
                busy_proc.wait(timeout=5)

    def test_provision_grub_cmdline_preservation(self):
        prov_script = os.path.join(REPO_ROOT, "provision-node.sh")
        with tempfile.TemporaryDirectory() as tmp:
            grub_file = os.path.join(tmp, "grub")
            with open(grub_file, "w", encoding="utf-8") as f:
                f.write('GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="iommu=pt quiet"\n')

            cmd = (
                f'sudo() {{ "$@"; }}; '
                f'PROVISION_NODE_SOURCE_ONLY=1 source "{prov_script}" && '
                f'update_grub_cmdline "{grub_file}" && '
                f'update_grub_cmdline "{grub_file}"'
            )
            subprocess.run(["bash", "-c", cmd], check=True)
            with open(grub_file, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertEqual(
                content,
                'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="iommu=pt quiet 8250.nr_uarts=0"\n',
            )

            # Existing custom 8250.nr_uarts=N value must not be overwritten
            with open(grub_file, "w", encoding="utf-8") as f:
                f.write('GRUB_CMDLINE_LINUX_DEFAULT="iommu=pt 8250.nr_uarts=4 quiet"\n')
            subprocess.run(["bash", "-c", cmd], check=True)
            with open(grub_file, "r", encoding="utf-8") as f:
                self.assertEqual(
                    f.read(),
                    'GRUB_CMDLINE_LINUX_DEFAULT="iommu=pt 8250.nr_uarts=4 quiet"\n',
                )

    def test_bootstrap_gemini_md_preservation_and_sync_drop_guard(self):
        boot_script = os.path.join(REPO_ROOT, "bootstrap-mesh.sh")
        sync_script = os.path.join(REPO_ROOT, "bin", "mesh-sync")
        with tempfile.TemporaryDirectory() as tmp:
            src_rule = os.path.join(tmp, "rendered.md")
            dst_gemini = os.path.join(tmp, "GEMINI.md")
            with open(src_rule, "w", encoding="utf-8") as f:
                f.write("# Antigravity NUMA Compute Mesh\nManaged body\n")

            # 1. Custom GEMINI.md must be preserved when OVERWRITE_GEMINI_MD=0
            with open(dst_gemini, "w", encoding="utf-8") as f:
                f.write("# Global Antigravity Agent Directives\nDo not clobber!\n")
            subprocess.run(
                [
                    "bash",
                    "-c",
                    f'BOOTSTRAP_MESH_SOURCE_ONLY=1 source "{boot_script}" --control-plane-only && '
                    f'install_gemini_md_if_safe "{src_rule}" "{dst_gemini}" "^# Antigravity NUMA Compute Mesh"',
                ],
                check=True,
                capture_output=True,
            )
            with open(dst_gemini, "r", encoding="utf-8") as f:
                self.assertIn("Do not clobber!", f.read())

            # 2. --overwrite-gemini-md replaces custom GEMINI.md
            subprocess.run(
                [
                    "bash",
                    "-c",
                    f'BOOTSTRAP_MESH_SOURCE_ONLY=1 source "{boot_script}" --control-plane-only --overwrite-gemini-md && '
                    f'install_gemini_md_if_safe "{src_rule}" "{dst_gemini}" "^# Antigravity NUMA Compute Mesh"',
                ],
                check=True,
                capture_output=True,
            )
            with open(dst_gemini, "r", encoding="utf-8") as f:
                self.assertIn("Managed body", f.read())

            # 3. mesh-sync drop rejects single-socket --target node1-node0
            conf = os.path.join(tmp, "cluster.conf")
            with open(conf, "w", encoding="utf-8") as f:
                f.write('MESH_NODES=("node1|192.168.1.210|00:11:22:33:44:10|2|tars|W1")\n')
            env = dict(os.environ)
            env["MESH_CONFIG"] = conf
            drop_res = subprocess.run(
                ["bash", sync_script, "drop", "demo", "--target", "node1-node0"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(drop_res.returncode, 1)
            self.assertIn("shared host bare repository", drop_res.stderr)


if __name__ == "__main__":
    unittest.main()
