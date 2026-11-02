"""Exercise the real standalone updater against signed, temporary app fixtures.

Usage: python3 Tests/test_updater.py /path/to/Repose-Ring-VERSION-AppleSilicon.zip
All installation targets and backups stay under a private temporary directory.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


PACKAGE = Path(sys.argv.pop(1)).resolve()
UPDATER = Path(__file__).resolve().parents[1] / "scripts/update-repose.command"


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="repose-updater-test-", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.apps = self.root / "Applications"
        self.backups = self.root / "Backups"
        self.target = self.apps / "Repose Ring.app"
        self.source = self.root / "source"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(PACKAGE), str(self.source)], check=True)
        self.app = self.source / "Repose Ring.app"
        self.package = self.root / PACKAGE.name
        shutil.copyfile(PACKAGE, self.package)
        self.manifest = self.root / "SHA256SUMS.txt"
        self.write_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self):
        digest = hashlib.sha256(self.package.read_bytes()).hexdigest()
        self.manifest.write_text(f"{digest}  {self.package.name}\n")

    @staticmethod
    def info(app):
        with open(app / "Contents/Info.plist", "rb") as file:
            return plistlib.load(file)

    def change_info(self, app, **changes):
        info = self.info(app)
        info.update(changes)
        with open(app / "Contents/Info.plist", "wb") as file:
            plistlib.dump(info, file)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
                       check=True, capture_output=True)

    def current_app(self, **changes):
        self.apps.mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.app, self.target)
        self.change_info(self.target, CFBundleVersion="1", **changes)
        self.previous_info = (self.target / "Contents/Info.plist").read_bytes()

    def repack(self):
        self.package.unlink()
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent",
                        str(self.app), str(self.package)], check=True)
        self.write_manifest()

    def run_update(self, *extra, env=None):
        return subprocess.run([
            "/bin/bash", str(UPDATER), "--package", str(self.package), "--checksum", str(self.manifest),
            "--install-dir", str(self.apps), "--backup-dir", str(self.backups), "--no-launch", *extra,
        ], text=True, capture_output=True, env=env, timeout=30)

    def assert_original_preserved(self):
        self.assertEqual((self.target / "Contents/Info.plist").read_bytes(), self.previous_info)
        self.assertFalse((self.apps / ".Repose-Ring-update.lock").exists())

    def test_check_only_has_no_installation_or_quarantine_side_effect(self):
        subprocess.run(["xattr", "-w", "com.apple.quarantine", "0081;0;UpdaterTest;", str(self.package)], check=True)
        result = self.run_update("--check-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.apps.exists())
        self.assertFalse(self.backups.exists())
        self.assertEqual(subprocess.run(["xattr", "-p", "com.apple.quarantine", str(self.package)],
                                        capture_output=True).returncode, 0)

    def test_checksum_mismatch_cannot_replace_existing_app(self):
        self.current_app()
        self.package.write_bytes(self.package.read_bytes() + b"tampered")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 不匹配", result.stderr)
        self.assert_original_preserved()

    def test_duplicate_checksum_entry_is_rejected(self):
        self.current_app()
        self.manifest.write_text(self.manifest.read_text() * 2)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_preserved()

    def test_wrong_payload_identity_is_rejected_even_with_valid_checksum_and_signature(self):
        self.current_app()
        self.change_info(self.app, CFBundleIdentifier="com.example.some-other-app")
        self.repack()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("应用标识不匹配", result.stderr)
        self.assert_original_preserved()

    def test_invalid_code_signature_is_rejected_after_checksum_passes(self):
        self.current_app()
        (self.app / "Contents/Resources/LICENSE").write_text("altered signed resource")
        self.repack()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("代码签名校验失败", result.stderr)
        self.assert_original_preserved()

    def test_archive_path_escape_is_rejected_before_extraction(self):
        self.current_app()
        self.package.unlink()
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("../escaped.txt", "must not escape")
        self.write_manifest()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("非预期路径", result.stderr)
        self.assertFalse((self.root / "escaped.txt").exists())
        self.assert_original_preserved()

    def test_an_unrelated_app_at_the_destination_is_not_replaced(self):
        self.current_app(CFBundleIdentifier="com.example.leave-this-alone")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("目标位置不是本项目应用", result.stderr)
        self.assert_original_preserved()

    def test_newer_installed_build_is_not_downgraded(self):
        self.current_app()
        self.change_info(self.target, CFBundleVersion=str(int(self.info(self.app)["CFBundleVersion"]) + 1))
        self.previous_info = (self.target / "Contents/Info.plist").read_bytes()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未降级", result.stderr)
        self.assert_original_preserved()

    def test_an_existing_update_lock_is_not_removed(self):
        self.current_app()
        lock = self.apps / ".Repose-Ring-update.lock"
        lock.mkdir()
        (lock / "pid").write_text(str(os.getpid()))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.exists())
        self.assertEqual((self.target / "Contents/Info.plist").read_bytes(), self.previous_info)

    def test_success_preserves_a_backup_and_leaves_unrelated_quarantine_untouched(self):
        self.current_app()
        unrelated = self.root / "Unrelated.app"
        unrelated.mkdir()
        subprocess.run(["xattr", "-w", "com.apple.quarantine", "0081;0;UpdaterTest;", str(unrelated)], check=True)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.info(self.target)["CFBundleVersion"], self.info(self.app)["CFBundleVersion"])
        backups = list(self.backups.glob("*/Repose Ring.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Contents/Info.plist").read_bytes(), self.previous_info)
        self.assertNotEqual(subprocess.run(["xattr", "-p", "com.apple.quarantine", str(self.target)],
                                           capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(["xattr", "-p", "com.apple.quarantine", str(unrelated)],
                                        capture_output=True).returncode, 0)
        self.assertFalse((self.apps / ".Repose-Ring-update.lock").exists())

    def test_post_replacement_failure_restores_the_original_app(self):
        self.current_app()
        # Test-only fault injection through Bash's environment, without shipping
        # failure switches or modifying any system utility.
        fault = self.root / "fault.sh"
        fault.write_text('''function /usr/bin/codesign {
    if [[ "${!#}" == "$REPOSE_TEST_FAIL_TARGET" ]]; then return 1; fi
    command /usr/bin/codesign "$@"
}
''')
        env = dict(os.environ, BASH_ENV=str(fault), REPOSE_TEST_FAIL_TARGET=str(self.target))
        result = self.run_update(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("已恢复原来的 Repose Ring", result.stdout)
        self.assert_original_preserved()


if __name__ == "__main__":
    unittest.main(verbosity=2)
