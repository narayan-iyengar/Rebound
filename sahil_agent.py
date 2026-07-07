#!/usr/bin/env python3
"""
Rebound Agent — Zero-intervention remote build + deploy.

Runs on any machine (e.g. work laptop). Uses the Anthropic API to:
  1. Read and edit Swift files (locally, on the machine running the agent)
  2. Commit and push to GitHub
  3. Remote build-check on the personal Mac over SSH (fast, no device)
  4. If errors: read affected files, fix, commit, rebuild — loop until clean
  5. Deploy via deploy.sh on the personal Mac (pull + Release build + install
     to iPhone; the Watch companion auto-pushes to the active paired Watch)

No per-command approval. Describe a task; the agent does everything.

MODERNIZED 2026-07-07 (was sahil_agent v2):
  - Model → claude-opus-4-8 (env REBOUND_AGENT_MODEL overrides)
  - Deploy now uses deploy.sh (xcodebuild) — the reliable pipeline. The old
    ios-deploy + devicectl-for-Watch path broke; devicectl timed out on WiFi
    after the paid-account switch. deploy.sh installs via xcodebuild targeting
    the iPhone UDID and the Watch companion auto-pushes to the active Watch.
  - Build-check is a fast generic Release compile (no device) for the fix loop.
  - Canonical design context: docs/SKYNET_AUTOSCORE_DESIGN.md.

Usage:
  python3 sahil_agent.py                       # interactive
  python3 sahil_agent.py "fix X and deploy"    # single-shot

Requires: ANTHROPIC_API_KEY env var, SSH access to the personal Mac,
          `pip install anthropic truststore`.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import truststore
    truststore.inject_into_ssl()
except Exception:
    pass
import anthropic

# ── Config ────────────────────────────────────────────────────────────────────
# REPO: where THIS agent reads/edits Swift (the machine running the agent).
# On the personal Mac itself, that's the same path as REMOTE_REPO.
# On a work laptop with a separate clone, point REPO at that clone.
REPO         = Path(os.environ.get("REBOUND_REPO", "/Users/narayan/SahilStats/SahilStatsLite/SahilStatsLite"))
PERSONAL_MAC = os.environ.get("REBOUND_MAC", "narayan@Narayans-MacBook-Pro.local")
REMOTE_REPO  = "/Users/narayan/SahilStats/SahilStatsLite/SahilStatsLite"
DEPLOY_SH    = "/Users/narayan/SahilStats/deploy.sh"
IPHONE_UDID  = "E52AFF08-9E71-52C0-8608-A9A529C5205C"   # xcrun devicectl / xcodebuild ID
MODEL        = os.environ.get("REBOUND_AGENT_MODEL", "claude-opus-4-8")

# Fast compile-check: generic iOS Release, no device needed. Same config as
# deploy.sh so errors match what a real deploy would hit.
BUILD_CHECK = f"""
cd {REMOTE_REPO}
git pull --rebase origin main 2>&1 | tail -2
echo '--- BUILD START ---'
xcodebuild \\
  -scheme SahilStatsLite \\
  -configuration Release \\
  -destination 'generic/platform=iOS' \\
  -allowProvisioningUpdates \\
  DEVELOPMENT_TEAM=TTV9QQRD5H \\
  CODE_SIGN_STYLE=Automatic \\
  2>&1 | grep -E 'error:|warning:|Build succeeded|BUILD SUCCEEDED|Build FAILED' \\
       | grep -v SourcePackages | head -60
echo '--- BUILD END ---'
"""

# ── Helpers ────────────────────────────────────────────────────────────────────

def _local(cmd: str, cwd=None) -> str:
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd or str(REPO))
    out = (r.stdout or "").strip()
    err = (r.stderr or "").strip()
    return (out + ("\n" + err if err else "")).strip() or "(no output)"

def _ssh(cmd: str, timeout=300) -> str:
    r = subprocess.run(["ssh", PERSONAL_MAC, cmd], capture_output=True, text=True, timeout=timeout)
    out = (r.stdout or "").strip()
    err = (r.stderr or "").strip()
    return (out + ("\n" + err if err else "")).strip() or "(no output)"

def _ssh_script(script: str, timeout=900) -> str:
    r = subprocess.run(["ssh", PERSONAL_MAC, "bash", "-s"],
                       input=script, capture_output=True, text=True, timeout=timeout)
    out = (r.stdout or "").strip()
    err = (r.stderr or "").strip()
    return (out + ("\n" + err if err else "")).strip() or "(no output)"

# ── Tools ─────────────────────────────────────────────────────────────────────

def read_file(path: str) -> str:
    f = REPO / path
    return f.read_text() if f.exists() else f"ERROR: {path} not found"

def write_file(path: str, content: str) -> str:
    f = REPO / path
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(content)
    return f"Written: {path}"

def list_files(directory: str = "") -> str:
    target = REPO / directory if directory else REPO
    if not target.exists():
        return f"ERROR: {directory} not found"
    files = sorted(
        str(f.relative_to(REPO))
        for f in target.rglob("*")
        if f.is_file() and ".git" not in f.parts and ".DS_Store" not in str(f)
    )
    return "\n".join(files[:500])

def run_local(command: str) -> str:
    return _local(command)

def git_commit_and_push(files: list[str], message: str) -> str:
    staged = []
    for f in files:
        _local(f"git add {f}")
        staged.append(f"staged: {f}")
    msg = f"{message}\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
    commit = _local(f"git commit -m {json.dumps(msg)}")
    push = _local("git push origin main")
    return "\n".join(staged + [commit, push])

def build() -> str:
    """Pull latest on the personal Mac and compile-check (generic Release, no device)."""
    return _ssh_script(BUILD_CHECK)

def deploy() -> str:
    """Run deploy.sh on the personal Mac: pull + Release build + install to iPhone.
    The Watch companion auto-pushes to whichever Watch is the active paired Watch."""
    return _ssh(f"bash {DEPLOY_SH}", timeout=900)

def check_devices() -> str:
    """Which devices are reachable (iPhone + both Watches)."""
    return _ssh("xcrun devicectl list devices 2>&1 | grep -E 'iPhone|Watch|iPad'")

def ssh_run(command: str) -> str:
    """Run an arbitrary command on the personal Mac."""
    return _ssh(command)

# ── Tool definitions ───────────────────────────────────────────────────────────

TOOLS = [
    {"name": "read_file", "description": "Read a file. Always read before editing.",
     "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
    {"name": "write_file", "description": "Write or overwrite a file with complete content.",
     "input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}},
    {"name": "list_files", "description": "List files in the repo or a subdirectory.",
     "input_schema": {"type": "object", "properties": {"directory": {"type": "string"}}}},
    {"name": "run_local", "description": "Run a shell command where the agent runs (git status, diff, log, grep).",
     "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}},
    {"name": "git_commit_and_push", "description": "Stage files, commit, push to GitHub.",
     "input_schema": {"type": "object", "properties": {"files": {"type": "array", "items": {"type": "string"}}, "message": {"type": "string"}}, "required": ["files", "message"]}},
    {"name": "build", "description": (
        "Pull latest on the personal Mac and compile-check (generic Release, no device — fast). "
        "Returns errors AND warnings. If errors exist: read the affected files, fix with write_file, "
        "commit with git_commit_and_push, call build again. Repeat until 'BUILD SUCCEEDED' with no errors."),
     "input_schema": {"type": "object", "properties": {}}},
    {"name": "deploy", "description": (
        "Run deploy.sh on the personal Mac: pull + Release build + install to iPhone. The Watch "
        "companion auto-pushes to the active paired Watch. Call build first and confirm it's clean. "
        "To deploy to the OTHER Watch, the user must switch the active Watch in the iPhone Watch app, "
        "then deploy again."),
     "input_schema": {"type": "object", "properties": {}}},
    {"name": "check_devices", "description": "Which devices are reachable (iPhone, both Watches).",
     "input_schema": {"type": "object", "properties": {}}},
    {"name": "ssh_run", "description": "Run an arbitrary command on the personal Mac.",
     "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}},
]

DISPATCH = {
    "read_file":           lambda i: read_file(i["path"]),
    "write_file":          lambda i: write_file(i["path"], i["content"]),
    "list_files":          lambda i: list_files(i.get("directory", "")),
    "run_local":           lambda i: run_local(i["command"]),
    "git_commit_and_push": lambda i: git_commit_and_push(i["files"], i["message"]),
    "build":               lambda i: build(),
    "deploy":              lambda i: deploy(),
    "check_devices":       lambda i: check_devices(),
    "ssh_run":             lambda i: ssh_run(i["command"]),
}

# ── System prompt ──────────────────────────────────────────────────────────────

SYSTEM = """You are the autonomous lead iOS developer for Rebound (repo dir still named SahilStatsLite).

You operate with ZERO user intervention. Given a task you:
1. Read files before editing (never assume content).
2. Make targeted, minimal changes matching surrounding style.
3. Commit and push with git_commit_and_push.
4. Call build to compile-check.
5. If build returns errors:
   - Parse each error for file + line
   - read_file the affected files, fix with write_file
   - git_commit_and_push the fixes, call build again
   - Repeat until BUILD SUCCEEDED with no errors (max 3 attempts)
   - NOTE: SourceKit-style "Cannot find X in scope" NEVER appears in xcodebuild
     output — the real compiler resolves the synchronized-root-group files fine.
     Only act on actual 'error:' lines from xcodebuild.
6. If clean and the task asked to deploy, call deploy.
7. Report concisely.

Never ask for confirmation. Never leave errors unfixed. If genuinely ambiguous,
make the most reasonable choice and proceed.

Canonical design doc: docs/SKYNET_AUTOSCORE_DESIGN.md — the Auto-Score Other
Memory. Read it before touching anything tracking/ball/shot related.

Current architecture (2026-07-07):
- SkynetProcessor (Swift actor) owns all tracking state — nonisolated methods,
  only @Published writes on @MainActor. SWIFT_STRICT_CONCURRENCY = minimal.
- YOLOv8n CoreML is the person detector (yolov8n.mlmodelc in bundle); Vision is
  fallback. Body pose runs alongside for ankle-based court contact.
- Auto court calibration: CourtHeatmapAccumulator builds a perspective CourtQuad
  from IMU-compensated ankle heatmap during warmup. PersonClassifier gates
  detections by courtQuad.contains().
- Player-centroid camera aim with foreground-occlusion robustness (§17):
  hold-on-collapse + per-frame velocity cap in AutoZoomManager.
- STRATEGIC PIVOT (§0): full-court ball tracking (BallNet-R) is SHELVED after 4
  experiments hit a data wall. Auto-scoring will be rim-region shot detection
  (§16), not ball tracking. Do not resurrect BallNet-R without cause.
- Gimbal: Kp 1.6, maxPanVelocity 1.5 rad/s. Pan + tilt PID + gravity drift.
- Recording 4K H.264; YouTube upload with COPPA/processing-abandoned/silent-fail
  fixes + per-game 'use different video' recovery.

Devices:
- iPhone 16 Pro Max — xcodebuild/devicectl ID E52AFF08-9E71-52C0-8608-A9A529C5205C
- Watch Series 8 (scoring remote) + Watch Ultra 2 (daily). deploy.sh installs to
  the iPhone; the Watch companion auto-pushes to whichever Watch is ACTIVE in the
  iPhone Watch app. To hit the other Watch, user switches active Watch, redeploy.

Known bug (filed, not urgent): YouTube uploads land on the wrong default channel
(@narayaniyengar6773 instead of @RealDeadlSahil). Needs a channel picker on OAuth.

No em-dashes in code comments. No placeholders. Lead with action.

Project context:
{context}
"""

# ── Context ────────────────────────────────────────────────────────────────────

def load_context() -> str:
    parts = []
    for fname in ["claude.md", "CLAUDE.md", "HANDOFF.md"]:
        p = REPO / fname
        if p.exists():
            parts.append(f"--- {fname} ---\n{p.read_text()}")
            break  # claude.md and CLAUDE.md are the same file on case-insensitive fs
    for fname in ["HANDOFF.md"]:
        p = REPO / fname
        if p.exists():
            parts.append(f"--- {fname} ---\n{p.read_text()}")
    return "\n\n".join(parts)

# ── Agent loop ─────────────────────────────────────────────────────────────────

def run(initial: str | None = None):
    client = anthropic.Anthropic()
    system = SYSTEM.format(context=load_context()[:12000])
    messages = []

    print(f"Rebound Agent — zero-intervention. Model: {MODEL}")
    print("Describe a task; the agent handles code, build, fix, deploy. 'quit' to exit.\n")

    while True:
        if initial:
            user_input, initial = initial, None
        else:
            try:
                user_input = input("You: ").strip()
            except (KeyboardInterrupt, EOFError):
                print("\nDone.")
                break
        if not user_input or user_input.lower() in ("quit", "q", "exit"):
            break

        messages.append({"role": "user", "content": user_input})

        while True:
            resp = client.messages.create(
                model=MODEL, max_tokens=8096, system=system, tools=TOOLS, messages=messages,
            )
            texts = [b.text for b in resp.content if hasattr(b, "text")]
            if texts:
                print(f"\nAgent: {''.join(texts)}\n")
            if resp.stop_reason != "tool_use":
                messages.append({"role": "assistant", "content": resp.content})
                break
            messages.append({"role": "assistant", "content": resp.content})
            results = []
            for block in resp.content:
                if block.type != "tool_use":
                    continue
                print(f"  [{block.name}] {json.dumps(block.input, ensure_ascii=False)[:80]}")
                try:
                    result = DISPATCH[block.name](block.input)
                except Exception as e:
                    result = f"ERROR: {e}"
                print(f"  → {result[:400]}{'…' if len(result) > 400 else ''}\n")
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": result})
            messages.append({"role": "user", "content": results})


if __name__ == "__main__":
    run(" ".join(sys.argv[1:]) or None)
