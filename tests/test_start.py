import base64
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import unittest


START = Path(__file__).resolve().parents[1] / "railway" / "start.sh"


class StartupKeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.volume = Path(self.temp.name) / "data"
        # Exercise the real key setup without launching nginx or the backend.
        self.script = START.read_text().split("cat > /etc/nginx/http.d/default.conf", 1)[0]
        self.script = self.script.replace("/app/data", str(self.volume))
        self.script = self.script.replace("/run/nofx-auth", str(Path(self.temp.name) / "auth"))
        self.script += '\nprintenv JWT_SECRET\n'

    def run_setup(self, **variables):
        env = {"PATH": os.environ["PATH"], "SETUP_PASSWORD": "synthetic_setup_password_123", **variables}
        return subprocess.run(
            ["/bin/sh", "-c", self.script],
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def test_missing_jwt_fails_without_generating_keys(self):
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JWT_SECRET is required", result.stderr)
        self.assertEqual(list(self.volume.iterdir()), [])

    def test_missing_setup_password_fails_closed(self):
        result = self.run_setup(JWT_SECRET=secrets.token_urlsafe(32), SETUP_PASSWORD="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SETUP_PASSWORD", result.stderr)

    def test_effective_jwt_changes_on_every_start(self):
        seed = secrets.token_urlsafe(32)
        first = self.run_setup(JWT_SECRET=seed)
        second = self.run_setup(JWT_SECRET=seed)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertRegex(first.stdout.strip(), r"^[a-f0-9]{64}$")
        self.assertNotEqual(first.stdout.strip(), seed)
        self.assertNotEqual(first.stdout, second.stdout)

    def test_registration_gate_is_scoped_and_password_is_hashed(self):
        result = self.run_setup(JWT_SECRET=secrets.token_urlsafe(32))
        self.assertEqual(result.returncode, 0, result.stderr)
        password_file = Path(self.temp.name) / "auth" / "registration.htpasswd"
        self.assertTrue(password_file.exists())
        stored = password_file.read_text()
        self.assertTrue(stored.startswith("setup:$6$"))
        self.assertNotIn("synthetic_setup_password_123", stored)
        source = START.read_text()
        self.assertIn("location ~ ^/api/register/?$", source)
        self.assertEqual(source.count('auth_basic "'), 1)
        general_api = source.split("location /api/ {", 1)[1].split("}\n", 1)[0]
        self.assertNotIn("auth_basic", general_api)
        self.assertNotIn('proxy_set_header Authorization ""', general_api)

    def test_generated_formats_and_permissions(self):
        result = self.run_setup(JWT_SECRET=secrets.token_urlsafe(32))
        self.assertEqual(result.returncode, 0, result.stderr)
        rsa = self.volume / "rsa_private_key.pem"
        aes = self.volume / "data_encryption_key"
        self.assertEqual(len(base64.b64decode(aes.read_text().strip(), validate=True)), 32)
        check = subprocess.run(
            ["openssl", "rsa", "-in", str(rsa), "-check", "-noout"],
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(check.returncode, 0, check.stderr)
        public = subprocess.run(
            ["openssl", "pkey", "-in", str(rsa), "-pubout"],
            capture_output=True, check=True, timeout=10,
        )
        info = subprocess.run(
            ["openssl", "pkey", "-pubin", "-text", "-noout"],
            input=public.stdout, capture_output=True, check=True, timeout=10,
        )
        self.assertIn(b"2048 bit", info.stdout.splitlines()[0])
        self.assertEqual(self.volume.stat().st_mode & 0o777, 0o700)
        for key in (rsa, aes):
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)

    def test_generated_keys_survive_second_start(self):
        jwt = secrets.token_urlsafe(32)
        self.assertEqual(self.run_setup(JWT_SECRET=jwt).returncode, 0)
        before = {p.name: p.read_bytes() for p in self.volume.iterdir()}
        self.assertEqual(self.run_setup(JWT_SECRET=jwt).returncode, 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.volume.iterdir()})

    def test_supplied_keys_do_not_create_fallback_files(self):
        self.assertEqual(self.run_setup(JWT_SECRET=secrets.token_urlsafe(32)).returncode, 0)
        rsa = (self.volume / "rsa_private_key.pem").read_text()
        for path in self.volume.iterdir():
            path.unlink()
        result = self.run_setup(
            JWT_SECRET=secrets.token_urlsafe(32),
            RSA_PRIVATE_KEY=rsa,
            DATA_ENCRYPTION_KEY=base64.b64encode(secrets.token_bytes(32)).decode(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.volume.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
