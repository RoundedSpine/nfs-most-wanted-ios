"""Exercise iOS preparation/reuse without proprietary inputs or Apple tools."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

GAME = Path(__file__).resolve().parents[2]
SCRIPT = GAME / "tools/setup_kit/setup.py"


@unittest.skipUnless(SCRIPT.is_file(), "game setup kit is outside standalone recomp-kit")
class IosPreparationTests(unittest.TestCase):
    def test_ios_keeps_asset_steps_and_invalidates_changed_translation_inputs(self):
        spec = importlib.util.spec_from_file_location("ios_setup_under_test", SCRIPT)
        setup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(setup)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").mkdir()
            (root / "tools/analyze.py").write_text("exporter driver")
            (root / "game.toml").write_text((GAME / "game.toml").read_text())
            (root / "globals.toml").write_text((GAME / "globals.toml").read_text())
            (root / "build").mkdir()
            calls = []
            def run(arguments, **kwargs):
                calls.append(list(map(str, arguments)))
                if str(arguments[1]) == "tools/analyze.py":
                    listings = root / "analysis/decompiled/speed.exe"
                    (listings / "functions").mkdir(parents=True, exist_ok=True)
                    (listings / "functions.tsv").write_text("address\tname\tbytes\n00400000\tfn\t1\n")
                    (listings / "functions/00400000.asm").write_text("00400000 NOP\n")
                    (listings.parent / "inputs.json").write_text(json.dumps({"executable_sha256": setup.PIN}))
                if "--translate-only" in arguments:
                    output = root / "build/recomp/gen"
                    output.mkdir(parents=True, exist_ok=True)
                    (output / "table.c").write_text("translated code")
            with patch.object(setup, "ROOT", root), patch.object(setup, "LOG", root / "build/setup.log"), \
                 patch.object(setup.platform, "machine", return_value="arm64"), \
                 patch.object(setup, "check_game", return_value=(root / "speed.exe", b"image")), \
                 patch.object(setup, "link_game"), patch.object(setup, "fetch", return_value=root), \
                 patch.object(setup, "ghidra_natives"), patch.object(setup, "run", side_effect=run), \
                 patch.object(setup.subprocess, "run", return_value=SimpleNamespace(returncode=2, stdout="no pack", stderr="")), \
                 patch("sys.argv", [str(SCRIPT), str(root), "--prepare-ios"]):
                setup.main()
                self.assertTrue(any("--translate-only" in call for call in calls))
                self.assertTrue(any("tools/effects/pools_bin.py" in call for call in calls))
                self.assertTrue(any("tools/effects/pools_fx.py" in call for call in calls))
                self.assertFalse(any("--target" in call for call in calls))
                self.assertFalse(any("tools/setup_kit/package.py" in call for call in calls))
                calls.clear()
                setup.main()
                self.assertFalse(any("tools/analyze.py" in call or "tools/build.py" in call for call in calls))
                with (root / "game.toml").open("a") as config:
                    config.write("\n# changed translation configuration\n")
                calls.clear()
                setup.main()
                self.assertTrue(any("--translate-only" in call for call in calls))
                self.assertFalse(any("tools/analyze.py" in call for call in calls))
                # Missing assembly must invalidate analysis, even when an old
                # manifest and functions.tsv are still present.
                (root / "analysis/decompiled/speed.exe/functions/00400000.asm").unlink()
                self.assertFalse(setup.analysis_done())
