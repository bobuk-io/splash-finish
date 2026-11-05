import hashlib
import importlib.util
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.archive = self.root / "SplashFinish-0.1.0-universal.zip"
        self.sums = self.root / "SHA256SUMS"

    def make_zip(self, entries):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            for name, value in entries.items():
                bundle.writestr(name, value)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.sums.write_text(f"{digest}  {self.archive.name}\n")

    def test_bin_selection(self):
        path, found = installer.choose_bin(f"/usr/bin:{self.root}/bin", self.root)
        self.assertEqual(path, self.root / "bin")
        self.assertTrue(found)
        self.assertEqual(installer.choose_bin("/usr/bin", self.root), (self.root / ".local/bin", False))

    def test_checksum_verification(self):
        self.make_zip({"Splash Finish.app/Contents/MacOS/SplashFinish": "binary"})
        installer.verify_checksum(self.archive, self.sums)
        self.sums.write_text("0" * 64 + f"  {self.archive.name}\n")
        with self.assertRaises(installer.InstallError):
            installer.verify_checksum(self.archive, self.sums)

    def test_archive_paths_and_symlinks(self):
        for bad in ["../../escape", "Splash Finish.app/../../escape", "/tmp/evil", "other.app/file", "Splash Finish.app/Contents\\escape"]:
            with self.subTest(bad=bad):
                self.make_zip({bad: "oops"})
                with self.assertRaises(installer.InstallError):
                    installer.check_archive(self.archive)
        with zipfile.ZipFile(self.archive, "w") as bundle:
            link = zipfile.ZipInfo("Splash Finish.app/Contents/link")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            bundle.writestr(link, "../../outside")
        with self.assertRaises(installer.InstallError):
            installer.check_archive(self.archive)

    def test_framework_relative_symlinks_are_safe(self):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("Splash Finish.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle", "binary")
            link = zipfile.ZipInfo("Splash Finish.app/Contents/Frameworks/Sparkle.framework/Versions/Current")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            bundle.writestr(link, "B")
        installer.check_archive(self.archive)
        with zipfile.ZipFile(self.archive, "a") as bundle:
            bundle.writestr("Splash Finish.app/Contents/Frameworks/Sparkle.framework/Versions/Current/evil", "no")
        with self.assertRaises(installer.InstallError):
            installer.check_archive(self.archive)

    def test_unrelated_bin_is_never_overwritten(self):
        self.make_zip({"Splash Finish.app/Contents/MacOS/SplashFinish": "binary"})
        bindir = self.root / "bin"
        bindir.mkdir()
        (bindir / "splash-finish").write_text("my command")
        with self.assertRaises(installer.InstallError):
            installer.install(self.archive, self.sums, self.root / "apps", bindir)
        self.assertEqual((bindir / "splash-finish").read_text(), "my command")

    def test_foreign_symlink_is_never_overwritten(self):
        self.make_zip({"Splash Finish.app/Contents/MacOS/SplashFinish": "binary"})
        bindir = self.root / "bin"
        bindir.mkdir()
        (bindir / "splash-finish").symlink_to("/tmp/other")
        with self.assertRaises(installer.InstallError):
            installer.install(self.archive, self.sums, self.root / "apps", bindir)
        self.assertEqual(os.readlink(bindir / "splash-finish"), "/tmp/other")

    def test_signature_must_match_developer(self):
        from subprocess import CompletedProcess
        with patch.object(installer, "run", side_effect=[CompletedProcess([], 0, "", ""), CompletedProcess([], 0, "", "TeamIdentifier=OTHER")]):
            with self.assertRaises(installer.InstallError):
                installer.verify_signature(self.root)
        details = "TeamIdentifier=S32B9D7R7D\nAuthority=Developer ID Application: Test"
        with patch.object(installer, "run", side_effect=[CompletedProcess([], 0, "", ""), CompletedProcess([], 0, "", details)]):
            installer.verify_signature(self.root)


if __name__ == "__main__":
    unittest.main()
