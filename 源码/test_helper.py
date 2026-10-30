"""Isolated macOS integration tests; never use the user's real key directory.

Run: python3 -m unittest discover -s <source-directory> -p test_helper.py -v
Set HELPER_SOURCE to exercise a different helper.sh against the bundled age.
"""

import hashlib
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest
import zipfile
import plistlib


SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent
RESOURCES = Path(os.environ.get("TEST_RESOURCES", ROOT / ".build-native/1P备份助手.app/Contents/Resources"))
ARCHIVER = Path(os.environ.get("ARCHIVE_TOOL", RESOURCES / "archive-tool"))


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="1p-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.resources = self.root / "resources"
        self.resources.mkdir()
        self.helper = self.resources / "helper.sh"
        shutil.copy2(os.environ.get("HELPER_SOURCE", SOURCE / "helper.sh"), self.helper)
        for name in ("age", "age-keygen"):
            (self.resources / name).symlink_to(RESOURCES / name)
        (self.resources / "archive-tool").symlink_to(ARCHIVER)
        self.keys = self.root / "keys"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), SUPPORT_DIR=str(self.keys),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        LC_ALL="en_US.UTF-8")
        self.run_helper("keygen")

    def command(self, *args):
        return ["/bin/bash", str(self.helper), *map(str, args)]

    def run_helper(self, *args, code=0):
        result = subprocess.run(self.command(*args), env=self.env, cwd=self.root,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        if code:
            self.assertNotIn("OK_PATH=", result.stdout)
        return result

    def source(self, name="backup.1pux", data=b"mock-password-data\x00\xff\n"):
        path = self.root / name
        path.write_bytes(data)
        return path

    def encrypt(self, src):
        self.run_helper("encrypt", src)
        return Path(str(src) + ".age")

    def mock_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o700)

    def assert_clean(self):
        self.assertEqual(list(self.root.rglob(".1p-backup.*")), [])
        self.assertEqual(list(self.root.rglob("*.1p-lock")), [])

    def test_roundtrip_unicode_spaces_quotes_and_permissions(self):
        src = self.source("\u5bc6\u7801 \u5907\u4efd ' \".1pux")
        data = src.read_bytes()
        encrypted = self.encrypt(src)
        self.run_helper("verify", encrypted)
        self.assertEqual(stat.S_IMODE(encrypted.stat().st_mode), 0o600)
        src.unlink()
        self.run_helper("decrypt", encrypted)
        self.assertEqual(src.read_bytes(), data)
        self.assertEqual(stat.S_IMODE(src.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.keys / "private.key").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.keys.stat().st_mode), 0o700)
        self.assert_clean()

    def test_backslash_filename_checksum(self):
        self.run_helper("verify", self.encrypt(self.source("a\\b.1pux")))

    def test_relative_dash_filename(self):
        src = self.source("-backup.1pux")
        self.run_helper("encrypt", src.name)
        self.run_helper("verify", src.name + ".age")

    def test_newline_path_rejected(self):
        self.run_helper("encrypt", self.source("line\nbreak.1pux"), code=24)

    def test_existing_ciphertext_preserved(self):
        src = self.source()
        encrypted = self.encrypt(src)
        before = encrypted.read_bytes()
        self.run_helper("encrypt", src, code=4)
        self.assertEqual(encrypted.read_bytes(), before)

    def test_existing_plaintext_preserved(self):
        src = self.source()
        before = src.read_bytes()
        encrypted = self.encrypt(src)
        self.run_helper("decrypt", encrypted, code=4)
        self.assertEqual(src.read_bytes(), before)

    def test_checksum_directory_rejected_before_encrypt(self):
        src = self.source()
        Path(str(src) + ".age.sha256").mkdir()
        self.run_helper("encrypt", src, code=4)
        self.assertFalse(Path(str(src) + ".age").exists())

    def test_checksum_symlink_does_not_overwrite_victim(self):
        src = self.source()
        victim = self.source("keep.txt", b"keep this")
        Path(str(src) + ".age.sha256").symlink_to(victim)
        self.run_helper("encrypt", src, code=4)
        self.assertEqual(victim.read_bytes(), b"keep this")

    def test_existing_checksum_preserved(self):
        src = self.source()
        side = Path(str(src) + ".age.sha256")
        side.write_text("existing checksum")
        self.run_helper("encrypt", src, code=4)
        self.assertEqual(side.read_text(), "existing checksum")

    def test_dangling_output_symlink_preserved(self):
        src = self.source()
        victim = self.root / "missing"
        out = Path(str(src) + ".age")
        out.symlink_to(victim)
        self.run_helper("encrypt", src, code=4)
        self.assertTrue(out.is_symlink())
        self.assertFalse(victim.exists())

    def test_hash_failure_not_reported_as_success(self):
        self.mock_command("shasum", "exit 1")
        src = self.source()
        self.run_helper("encrypt", src, code=21)
        self.assertFalse(Path(str(src) + ".age").exists())
        self.assert_clean()

    def test_temp_creation_failure(self):
        self.mock_command("mktemp", "exit 1")
        self.run_helper("encrypt", self.source(), code=21)
        self.assert_clean()

    def test_checksum_write_failure(self):
        # Inject a directory where the staged checksum would be written.
        self.mock_command("mktemp", 'p=$(/usr/bin/mktemp "$@") || exit 1\n'
                          'mkdir "$p/checksum"\nprintf "%s\\n" "$p"')
        src = self.source()
        self.run_helper("encrypt", src, code=21)
        self.assertFalse(Path(str(src) + ".age").exists())
        self.assert_clean()

    def test_missing_private_does_not_rotate_public(self):
        pub = self.keys / "public.key"
        before = pub.read_bytes()
        (self.keys / "private.key").unlink()
        self.run_helper("keygen", code=20)
        self.assertEqual(pub.read_bytes(), before)
        self.assertFalse((self.keys / "private.key").exists())
        self.assert_clean()

    def test_public_only_encryption_and_verify(self):
        (self.keys / "private.key").unlink()
        encrypted = self.encrypt(self.source())
        self.run_helper("verify", encrypted)
        self.run_helper("decrypt", encrypted, code=7)

    def test_missing_and_empty_public_recovery(self):
        pub = self.keys / "public.key"
        expected = pub.read_bytes()
        priv = (self.keys / "private.key").read_bytes()
        pub.unlink()
        self.run_helper("keygen")
        self.assertEqual(pub.read_bytes(), expected)
        pub.write_bytes(b"")
        self.run_helper("keygen")
        self.assertEqual(pub.read_bytes(), expected)
        self.assertEqual((self.keys / "private.key").read_bytes(), priv)
        self.run_helper("selftest")
        self.assert_clean()

    def test_existing_keys_preserved(self):
        priv = (self.keys / "private.key").read_bytes()
        self.run_helper("keygen", code=9)
        self.assertEqual((self.keys / "private.key").read_bytes(), priv)

    def test_invalid_private_recovery_leaves_no_public(self):
        (self.keys / "public.key").unlink()
        (self.keys / "private.key").write_text("invalid key\n")
        self.run_helper("keygen", code=10)
        self.assertFalse((self.keys / "public.key").exists())
        self.assert_clean()

    def test_selftest(self):
        self.run_helper("selftest")
        self.assert_clean()

    def test_wrong_private_and_corrupt_ciphertext_leave_no_plaintext(self):
        src = self.source(data=b"sensitive test data" * 10000)
        encrypted = self.encrypt(src)
        src.unlink()
        private = self.keys / "private.key"
        original = private.read_bytes()
        private.unlink()
        subprocess.run([str(RESOURCES / "age-keygen"), "-o", str(private)],
                       check=True, capture_output=True)
        self.run_helper("decrypt", encrypted, code=8)
        self.assertFalse(src.exists())
        private.write_bytes(original)
        encrypted.write_bytes(encrypted.read_bytes()[:-10])
        self.run_helper("decrypt", encrypted, code=8)
        self.assertFalse(src.exists())
        self.assert_clean()

    def test_verify_corrupt_and_malformed_checksum(self):
        encrypted = self.encrypt(self.source())
        encrypted.write_bytes(encrypted.read_bytes() + b"corruption")
        self.run_helper("verify", encrypted, code=18)
        side = Path(str(encrypted) + ".sha256")
        side.write_text("a" + "z" * 63 + "  backup.age\n")
        self.run_helper("verify", encrypted, code=17)
        side.unlink()
        self.run_helper("verify", encrypted, code=16)

    def test_reencrypt_raw_and_armored_ciphertext(self):
        src = self.source()
        encrypted = self.encrypt(src)
        self.run_helper("encrypt", encrypted, code=19)
        armored = self.root / "armored.age"
        subprocess.run([str(RESOURCES / "age"), "-a", "-R",
                        str(self.keys / "public.key"), "-o", str(armored), str(src)],
                       check=True, capture_output=True)
        self.run_helper("encrypt", armored, code=19)
        self.run_helper("decrypt", armored)
        self.assertEqual((self.root / "armored").read_bytes(), src.read_bytes())

    def test_missing_binaries_use_expected_exit_codes(self):
        for name, code in (("age", 90), ("age-keygen", 91)):
            path = self.resources / name
            path.unlink()
            self.run_helper("status", code=code)
            path.symlink_to(RESOURCES / name)

    def test_permissions_failure_is_not_ignored(self):
        src = self.source()
        encrypted = self.encrypt(src)
        src.unlink()
        self.mock_command("chmod", "exit 1")
        self.run_helper("decrypt", encrypted, code=23)
        self.assertFalse(src.exists())

    def test_private_symlink_rejected(self):
        encrypted = self.encrypt(self.source())
        private = self.keys / "private.key"
        saved = self.root / "saved-private.key"
        private.rename(saved)
        private.symlink_to(saved)
        self.run_helper("decrypt", encrypted, code=23)
        self.run_helper("keygen", code=23)

    def test_verify_hash_read_failure(self):
        encrypted = self.encrypt(self.source())
        self.mock_command("shasum", "exit 1")
        self.run_helper("verify", encrypted, code=21)

    def test_concurrent_encryption_single_winner(self):
        src = self.source(data=b"test concurrency\n" * 10000)
        processes = [subprocess.Popen(self.command("encrypt", src), env=self.env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for _ in range(8)]
        results = [(p.communicate(timeout=20), p.returncode) for p in processes]
        codes = [code for _, code in results]
        self.assertEqual(codes.count(0), 1, results)
        self.assertTrue(all(code in (0, 4, 22) for code in codes), results)
        self.run_helper("verify", str(src) + ".age")
        self.assert_clean()

    def test_concurrent_keygen_single_winner(self):
        shutil.rmtree(self.keys)
        processes = [subprocess.Popen(self.command("keygen"), env=self.env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for _ in range(8)]
        results = [(p.communicate(timeout=20), p.returncode) for p in processes]
        codes = [code for _, code in results]
        self.assertEqual(codes.count(0), 1, results)
        self.assertTrue(all(code in (0, 9, 22) for code in codes), results)
        self.run_helper("selftest")
        self.assert_clean()

    def test_termination_cleans_unpublished_plaintext(self):
        encrypted = self.encrypt(self.source())
        (self.root / "backup.1pux").unlink()
        age = self.resources / "age"
        age.unlink()
        age.write_text('#!/bin/bash\nprintf "partial plaintext" > "$5"\n'
                       'sleep 20 &\nworker=$!\ntouch "$SUPPORT_DIR/started"\n'
                       'wait "$worker"\nexit 1\n')
        age.chmod(0o700)
        process = subprocess.Popen(self.command("decrypt", encrypted), env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.keys / "started").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.keys / "started").exists())
            self.assertFalse((self.root / "backup.1pux").exists())
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
                raise
        self.assertNotEqual(process.returncode, 0)
        self.assert_clean()

    def test_empty_input_rejected(self):
        self.run_helper("encrypt", self.source(data=b""), code=11)

    def folder_cipher(self, folder):
        self.run_helper("encrypt", folder)
        return Path(str(folder) + ".folder.zip.age")

    def malicious_folder_cipher(self, entries):
        archive = self.root / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(".1p-folder-format", "1P backup folder ZIP v1\n")
            for name, data, mode in entries:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                z.writestr(info, data)
        cipher = self.root / "hostile.folder.zip.age"
        subprocess.run([str(RESOURCES / "age"), "-R", str(self.keys / "public.key"),
                        "-o", str(cipher), str(archive)], check=True, capture_output=True)
        return cipher

    def test_folder_roundtrip_nested_hidden_empty_unicode(self):
        folder = self.root / "\u6574\u4e2a \u6587\u4ef6\u5939"
        (folder / "\u5b50\u76ee\u5f55" / "empty").mkdir(parents=True)
        entries = {"a.1pux": b"mock backup\x00\xff", ".hidden": b"hidden", "\u5b50\u76ee\u5f55/line\nbreak": b"data"}
        for name, data in entries.items():
            (folder / name).write_bytes(data)
        cipher = self.folder_cipher(folder)
        self.run_helper("verify", cipher)
        self.run_helper("decrypt", cipher, code=4)
        shutil.rmtree(folder)
        r = self.run_helper("decrypt", cipher)
        self.assertIn("OK_KIND=folder", r.stdout)
        for name, data in entries.items():
            self.assertEqual((folder / name).read_bytes(), data)
            self.assertEqual(stat.S_IMODE((folder / name).stat().st_mode), 0o600)
        self.assertTrue((folder / "\u5b50\u76ee\u5f55/empty").is_dir())
        self.assert_clean()

    def test_empty_folder_roundtrip(self):
        folder = self.root / "empty"
        folder.mkdir()
        cipher = self.folder_cipher(folder)
        folder.rmdir()
        self.run_helper("decrypt", cipher)
        self.assertTrue(folder.is_dir())
        self.assertEqual(list(folder.iterdir()), [])

    def test_folder_archive_remains_standard_zip(self):
        folder = self.root / "folder"
        folder.mkdir()
        (folder / "test.txt").write_text("portable data")
        cipher = self.folder_cipher(folder)
        archive = self.root / "portable.zip"
        subprocess.run([str(RESOURCES / "age"), "-d", "-i", str(self.keys / "private.key"),
                        "-o", str(archive), str(cipher)], check=True, capture_output=True)
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(z.read("contents/test.txt"), b"portable data")
            self.assertEqual(z.read(".1p-folder-format"), b"1P backup folder ZIP v1\n")

    def test_renamed_folder_cipher_restores_to_folder(self):
        folder = self.root / "folder"
        folder.mkdir()
        cipher = self.folder_cipher(folder)
        renamed = self.root / "renamed.age"
        cipher.rename(renamed)
        self.run_helper("decrypt", renamed)
        self.assertTrue((self.root / "renamed.folder").is_dir())

    def test_regular_zip_not_auto_extracted_by_suffix(self):
        src = self.root / "ordinary.folder.zip"
        with zipfile.ZipFile(src, "w") as z:
            z.writestr("just-a-file", "hello")
        before = src.read_bytes()
        cipher = self.encrypt(src)
        src.unlink()
        self.run_helper("decrypt", cipher)
        self.assertEqual(src.read_bytes(), before)
        self.assertFalse((self.root / "ordinary").exists())

    def test_folder_links_and_special_files_rejected(self):
        folder = self.root / "folder"
        folder.mkdir()
        (folder / "link").symlink_to(self.source("outside", b"never include"))
        self.run_helper("encrypt", folder, code=26)
        self.assertFalse(Path(str(folder) + ".folder.zip.age").exists())
        (folder / "link").unlink()
        os.mkfifo(folder / "pipe")
        self.run_helper("encrypt", folder, code=26)
        self.assert_clean()

    def test_archive_path_traversal_rejected(self):
        for name in ["../escape", "/tmp/escape", "contents/../../escape", "contents/../escape", "contents\\..\\..\\escape"]:
            cipher = self.malicious_folder_cipher([(name, b"bad", stat.S_IFREG | 0o600)])
            self.run_helper("decrypt", cipher, code=27)
            self.assertFalse((self.root / "hostile").exists())
            self.assertFalse((self.root / "escape").exists())
            cipher.unlink()
            (self.root / "fixture.zip").unlink()
        self.assert_clean()

    def test_archive_symlink_and_duplicate_rejected(self):
        cipher = self.malicious_folder_cipher([("contents/link", b"../../escape", stat.S_IFLNK | 0o777)])
        self.run_helper("decrypt", cipher, code=27)
        self.assertFalse((self.root / "hostile").exists())
        cipher.unlink()
        (self.root / "fixture.zip").unlink()
        with self.assertWarns(UserWarning):
            cipher = self.malicious_folder_cipher([("contents/file", b"one", stat.S_IFREG | 0o600),
                                                    ("contents/file", b"two", stat.S_IFREG | 0o600)])
        self.run_helper("decrypt", cipher, code=27)
        self.assertFalse((self.root / "hostile").exists())
        self.assert_clean()

    def test_custom_key_settings_shared_with_cli(self):
        settings = self.root / "settings.plist"
        settings.write_bytes(plistlib.dumps({"keyDirectory": str(self.keys)}))
        self.env.pop("SUPPORT_DIR")
        self.env["ONEP_SETTINGS_PATH"] = str(settings)
        self.assertIn("HAS_PRIV=1", self.run_helper("status").stdout)
        settings.write_bytes(plistlib.dumps({"keyDirectory": str(self.root / "unplugged-drive")}))
        self.run_helper("keygen", code=25)
        self.assertFalse((self.root / "unplugged-drive").exists())
        settings.write_bytes(b"malformed plist")
        self.run_helper("status", code=25)

    def test_validate_key_directory_pair(self):
        self.run_helper("checkkeys")
        pub = self.keys / "public.key"
        pub.write_text("invalid public key")
        self.run_helper("checkkeys", code=12)
        pub.unlink()
        self.run_helper("checkkeys")
        (self.keys / "private.key").write_text("not a valid private key")
        self.run_helper("checkkeys", code=10)

    def test_large_no_newline_input(self):
        src = self.source(data=b"a" * (8 * 1024 * 1024))
        expected = hashlib.sha256(src.read_bytes()).digest()
        encrypted = self.encrypt(src)
        src.unlink()
        self.run_helper("decrypt", encrypted)
        self.assertEqual(hashlib.sha256(src.read_bytes()).digest(), expected)


if __name__ == "__main__":
    unittest.main()
