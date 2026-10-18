#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$project_dir" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="swiftcull-commit-message-") as temporary:
    repo = Path(temporary)
    # Isolate all Git configuration; no commits or application data are created.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def run(*args):
        return subprocess.run(args, cwd=repo, env=env, capture_output=True, text=True)

    assert run("git", "init", "--quiet").returncode == 0
    for relative in (".githooks/commit-msg", ".agent/setup-git-hooks.sh"):
        destination = repo / relative
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(source / relative, destination)

    cases = [(f"{prefix}: update photo export\n", True) for prefix in
             ("feat", "fix", "perf", "refactor", "docs", "style", "test", "chore", "ci", "revert")]
    cases += [
        ("docs: update README\n\n- Explain local setup.\n- Keep examples concise.\n", True),
        ("docs: update README\n\n# Editor comment\n", True),
        ("docs: update README\n\n- Document `SwiftCull.app` and macOS 14+.\n", True),
        ("", False),
        ("# Comments only\n", False),
        ("update README\n", False),
        ("unknown: update README\n", False),
        ("docs:update README\n", False),
        ("docs: \n", False),
        ("docs: 更新说明\n", False),
        ("docs: update README\n- Explain setup.\n", False),
        ("docs: update README\n\nExplain setup.\n", False),
        ("docs: update README\n\n- 更新说明\n", False),
        ("docs: update README\n\n- \n", False),
    ]
    message = repo / "message.txt"
    for text, expected in cases:
        message.write_text(text)
        result = run(str(repo / ".githooks/commit-msg"), str(message))
        assert (result.returncode == 0) == expected, (text, result.stderr)
        assert message.read_text() == text, "Hook must not rewrite the message"

    setup = str(repo / ".agent/setup-git-hooks.sh")
    active_hook = repo / ".git/hooks/pre-commit"
    active_hook.write_text("#!/bin/sh\nexit 0\n")
    active_hook.chmod(0o755)
    assert run("bash", setup).returncode != 0
    active_hook.unlink()
    assert run("git", "config", "--local", "core.hooksPath", "custom-hooks").returncode == 0
    assert run("bash", setup).returncode != 0
    assert run("git", "config", "--get", "core.hooksPath").stdout.strip() == "custom-hooks"
    assert run("git", "config", "--local", "--unset", "core.hooksPath").returncode == 0
    assert run("bash", setup).returncode == 0
    assert run("bash", setup).returncode == 0
    assert run("git", "config", "--local", "--get", "core.hooksPath").stdout.strip() == ".githooks"
    print(f"Passed {len(cases)} message cases and hook installation checks.")
PY
