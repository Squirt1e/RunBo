#!/usr/bin/env python3
"""Isolated orchestration checks: mocked build/compiler/launchctl; never quits or opens an App."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class AppIdentityChecks(unittest.TestCase):
    def test_identity_plist_is_complete(self):
        with (ROOT / "config/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertTrue(info["CFBundleName"])
        self.assertTrue(info["CFBundleDisplayName"])
        self.assertTrue(info["CFBundleExecutable"])
        self.assertTrue(info["CFBundleIdentifier"])


class RebuildRestartChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="runbo-rebuild-check-")
        self.root = Path(self.temp.name) / "project with spaces"
        scripts = self.root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("rebuild-and-restart.sh", "restart-built-app.swift"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        config = self.root / "config"
        config.mkdir(parents=True)
        shutil.copy2(ROOT / "config/Info.plist", config / "Info.plist")
        with (ROOT / "config/Info.plist").open("rb") as source:
            self.info = plistlib.load(source)
        self.app_name = self.info["CFBundleName"]
        self.original = self.root / f"build/{self.app_name}.app/original"
        self.original.parent.mkdir(parents=True)
        self.original.write_text("running-package")
        self.trace = self.root / "trace"
        self.submit = self.root / "submit.json"
        tools = self.root / "tools"
        tools.mkdir()
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        TEST_TRACE=str(self.trace), TEST_SUBMIT=str(self.submit))
        self.env.pop("TEST_FAIL", None)
        compiler = tools / "swiftc"
        compiler.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ['TEST_TRACE'], 'a') as f: f.write('compile\\n')
if os.environ.get('TEST_FAIL') == 'compile': sys.exit(8)
p = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
p.write_text('''#!/bin/sh
printf 'check:%s\\\\n' "$1" >> "$TEST_TRACE"
if [ "$TEST_FAIL" = check ]; then exit 10; fi
''')
p.chmod(0o700)
""")
        compiler.chmod(0o700)
        launcher = tools / "launchctl"
        launcher.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_TRACE'], 'a') as f: f.write('submit\\n')
with open(os.environ['TEST_SUBMIT'], 'w') as f: json.dump(sys.argv[1:], f)
if os.environ.get('TEST_FAIL') == 'submit': sys.exit(11)
""")
        launcher.chmod(0o700)
        (scripts / "build-app.sh").write_text("""#!/bin/bash
set -eu
printf 'build:%s\\n' "$1" >> "$TEST_TRACE"
mkdir -p "$APP_OUTPUT_PATH"
printf 'new-package' > "$APP_OUTPUT_PATH/new"
if [ "${TEST_FAIL:-}" = build ]; then exit 9; fi
""")

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args, failure=None):
        env = dict(self.env)
        if failure:
            env["TEST_FAIL"] = failure
        result = subprocess.run(["bash", str(self.root / "scripts/rebuild-and-restart.sh"), *args],
                                cwd=self.temp.name, env=env, text=True, capture_output=True)
        self.assertEqual(self.original.read_text(), "running-package", "parent must not replace a running package")
        return result

    def events(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_check_builds_separately_without_handoff(self):
        result = self.run_script("debug", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["compile", "build:debug", "check:--check"])
        self.assertFalse(self.submit.exists())
        self.assertIn("no App was quit, replaced or launched", result.stdout)
        stages = list((self.root / "build").glob(f".rebuild.*/{self.app_name}.app/new"))
        self.assertEqual(len(stages), 1)

    def test_success_only_hands_off_after_build_and_preflight(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["compile", "build:debug", "check:--check", "submit"])
        arguments = json.loads(self.submit.read_text())
        self.assertEqual(arguments[0], "submit")
        self.assertIn("/bin/sh", arguments)
        self.assertIn("--restart", arguments[arguments.index("-c") + 1])
        self.assertIn(str(self.original.parent), arguments)
        self.assertTrue(any(".rebuild." in arg and arg.endswith(f"/{self.app_name}.app") for arg in arguments))
        self.assertIn("Restart scheduled", result.stdout)

    def test_release_configuration(self):
        result = self.run_script("release", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build:release", self.events())

    def test_unknown_arguments_fail_before_build(self):
        result = self.run_script("--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.events(), [])

    def assert_failed_safely(self, failure, code, expected_events):
        result = self.run_script(failure=failure)
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(self.events(), expected_events)
        self.assertEqual(list((self.root / "build").glob(".rebuild.*")), [])

    def test_compiler_failure_never_builds_or_submits(self):
        self.assert_failed_safely("compile", 8, ["compile"])

    def test_build_failure_never_submits(self):
        self.assert_failed_safely("build", 9, ["compile", "build:debug"])

    def test_preflight_failure_never_submits(self):
        self.assert_failed_safely("check", 10, ["compile", "build:debug", "check:--check"])

    def test_submit_failure_preserves_running_package_and_cleans_stage(self):
        self.assert_failed_safely("submit", 11, ["compile", "build:debug", "check:--check", "submit"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
