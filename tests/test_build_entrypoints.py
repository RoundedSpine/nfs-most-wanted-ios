"""Build aliases delegate signing, configuration and quoting to one builder."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="shell entry points need bash")


def invoke(tmp_path, script, arguments, team=None):
    root = tmp_path / "checkout with spaces"
    root.mkdir()
    for name in ("ios-build.sh", "github-actions-ios-build.sh"):
        shutil.copy2(ROOT / name, root / name)
    python = root / ".venv/bin/python"
    python.parent.mkdir(parents=True)
    python.write_text("#!%s\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n" % sys.executable)
    python.chmod(0o755)
    env = dict(os.environ)
    env.pop("RECOMP_IOS_TEAM", None)
    if team:
        env["RECOMP_IOS_TEAM"] = team
    result = subprocess.run([str(root / script), *arguments], cwd=tmp_path, env=env,
                            text=True, capture_output=True, check=True)
    return root, json.loads(result.stdout)


def test_ci_build_forwards_unsigned_configuration_and_options(tmp_path):
    root, args = invoke(tmp_path, "github-actions-ios-build.sh", ["Release", "--jobs", "3"])
    assert args == [str(root / "tools/build.py"), "--target", "ios", "--unsigned",
                    "--no-install", "--config", "Release", "--jobs", "3"]
    assert "--team" not in args


def test_ci_build_default_and_explicit_configuration(tmp_path):
    root, args = invoke(tmp_path, "github-actions-ios-build.sh", ["--config", "Release"])
    assert args == [str(root / "tools/build.py"), "--target", "ios", "--unsigned",
                    "--no-install", "--config", "Release"]


@pytest.mark.parametrize("arguments,expected", [
    (["TEAM123", "--jobs", "2"], ["--team", "TEAM123", "--jobs", "2"]),
    (["--team", "TEAM456"], ["--team", "TEAM456"]),
    (["--unsigned"], ["--unsigned"]),
    (["--console"], ["--console"]),
])
def test_local_build_keeps_positional_team_and_option_based_calls(tmp_path, arguments, expected):
    root, args = invoke(tmp_path, "ios-build.sh", arguments, team="ENVTEAM")
    assert args == [str(root / "tools/build.py"), "--target", "ios", *expected]


def test_setup_prefers_supported_python_without_ci_path_shim(tmp_path):
    root = tmp_path / "setup"
    root.mkdir()
    shutil.copy2(ROOT / "setup.sh", root / "setup.sh")
    (root / "kit/tools").mkdir(parents=True)
    (root / "kit/tools/setup.py").touch()
    bin_dir = root / "bin"
    bin_dir.mkdir()
    for name, body in {
        "uname": "echo arm64",
        "xcode-select": "exit 0",
        "python3.13": "echo unsupported-python-selected; exit 3",
        "python3.12": 'if [ "$1" = "-c" ]; then exit 0; fi; echo supported-python-selected',
    }.items():
        path = bin_dir / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
    result = subprocess.run(["/bin/sh", str(root / "setup.sh"), "game", "--check-only"],
                            cwd=tmp_path,
                            env={**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", "")},
                            text=True, capture_output=True, check=True)
    assert result.stderr == ""
    assert "supported-python-selected" in result.stdout
    assert "unsupported-python-selected" not in result.stdout
