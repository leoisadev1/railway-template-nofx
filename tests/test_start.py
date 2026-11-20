import base64
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import unittest


RAILWAY = Path(__file__).resolve().parents[1] / "railway"
START = RAILWAY / "start.sh"
SERVE = RAILWAY / "serve.sh"
MARKER = "# --- end of unit-tested setup ---"


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.volume = root / "data"
        self.run_dir = root / "run"
        self.conf = self.run_dir / "conf"
        # Exercise the real setup without the chown, setpriv, nginx or backend.
        start = START.read_text()
        self.assertIn(MARKER, start)
        self.assertEqual(start.count('[ "$(id -u)" -ne 0 ]'), 1)
        start = start.split(MARKER, 1)[0].replace('[ "$(id -u)" -ne 0 ]', "[ 0 -ne 0 ]")
        self.start = start.replace("/run/nofx", str(self.run_dir))
        self.start += "\nprintenv JWT_SECRET\nprintenv EXPERIENCE_IMPROVEMENT\n"
        serve = SERVE.read_text()
        self.assertIn(MARKER, serve)
        self.assertEqual(serve.count('[ "$(id -u)" -eq 0 ]'), 1)
        serve = serve.split(MARKER, 1)[0].replace('[ "$(id -u)" -eq 0 ]', "[ 1 -eq 0 ]")
        self.serve = serve.replace("/app/data", str(self.volume))

    def run_script(self, script, variables):
        return subprocess.run(
            ["/bin/sh", "-c", script],
            env={"PATH": os.environ["PATH"], **variables},
            text=True,
            capture_output=True,
            timeout=15,
        )

    def run_start(self, **variables):
        return self.run_script(self.start, {"SETUP_PASSWORD": "synthetic_setup_password_123", **variables})

    def run_serve(self, **variables):
        return self.run_script(self.serve, variables)

    def test_missing_jwt_fails_before_writing_anything(self):
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JWT_SECRET is required", result.stderr)
        self.assertFalse(self.run_dir.exists())

    def test_missing_setup_password_fails_closed(self):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), SETUP_PASSWORD="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SETUP_PASSWORD", result.stderr)
        self.assertFalse(self.run_dir.exists())

    def test_non_numeric_port_fails_closed(self):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), PORT="8080; include /etc/passwd")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PORT must be a number", result.stderr)

    def test_real_start_refuses_to_run_unprivileged(self):
        if os.geteuid() == 0:
            self.skipTest("runs as root")
        result = self.run_script(START.read_text(), {
            "JWT_SECRET": secrets.token_urlsafe(32),
            "SETUP_PASSWORD": "synthetic_setup_password_123",
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must start as root", result.stderr)

    def test_effective_jwt_changes_on_every_start(self):
        seed = secrets.token_urlsafe(32)
        first = self.run_start(JWT_SECRET=seed)
        second = self.run_start(JWT_SECRET=seed)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        jwt = first.stdout.splitlines()[0]
        self.assertRegex(jwt, r"^[a-f0-9]{64}$")
        self.assertNotEqual(jwt, seed)
        self.assertNotEqual(jwt, second.stdout.splitlines()[0])

    def test_usage_telemetry_is_off_unless_opted_in(self):
        default = self.run_start(JWT_SECRET=secrets.token_urlsafe(32))
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual(default.stdout.splitlines()[1], "false")
        opted = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), EXPERIENCE_IMPROVEMENT="true")
        self.assertEqual(opted.stdout.splitlines()[1], "true")

    def test_registration_gate_is_scoped_and_password_is_hashed(self):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32))
        self.assertEqual(result.returncode, 0, result.stderr)
        password_file = self.conf / "registration.htpasswd"
        stored = password_file.read_text()
        self.assertTrue(stored.startswith("setup:$6$"))
        self.assertNotIn("synthetic_setup_password_123", stored)
        for path in (password_file, self.conf / "nginx.conf"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        config = (self.conf / "nginx.conf").read_text()
        self.assertNotIn("synthetic_setup_password_123", config)
        self.assertIn(f"auth_basic_user_file {password_file};", config)
        self.assertIn("listen 8080;", config)
        self.assertIn("location ~ ^/api/register/?$", config)
        self.assertEqual(config.count('auth_basic "'), 1)
        general_api = config.split("location /api/ {", 1)[1].split("}\n", 1)[0]
        self.assertNotIn("auth_basic", general_api)
        self.assertNotIn('proxy_set_header Authorization ""', general_api)
        # The backend trusts the client address nginx sends; nginx must set it in
        # every proxied location, /health included, never pass on the client's.
        blocks = config.split("proxy_pass ")[1:]
        self.assertEqual(len(blocks), 5)
        self.assertTrue(blocks[0].startswith("http://127.0.0.1:8081/api/health;"))
        for block in blocks:
            body = block.split("}", 1)[0]
            self.assertIn("proxy_set_header X-Forwarded-For $remote_addr;", body)
            self.assertIn("proxy_set_header X-Real-IP $remote_addr;", body)

    def real_ip_sources(self):
        config = (self.conf / "nginx.conf").read_text()
        return [line.strip() for line in config.splitlines() if "set_real_ip_from" in line]

    def test_only_railway_edge_may_set_the_client_address_by_default(self):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.real_ip_sources(), ["set_real_ip_from 100.64.0.0/10;"])

    def real_ip_directives(self, **variables):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), **variables)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.conf / "nginx.conf").read_text()
        return [line.strip() for line in config.splitlines() if line.strip().startswith("real_ip_")]

    def test_client_address_comes_from_the_edge_x_real_ip(self):
        # Railway's edge sends X-Forwarded-For: <client>, <edge public address>.
        # Walking that right to left yields the shared edge address, so by default
        # nginx reads X-Real-IP, which the edge sets to the client, without recursion.
        self.assertEqual(self.real_ip_directives(), ["real_ip_header X-Real-IP;"])
        self.assertEqual(self.real_ip_directives(EDGE_CLIENT_IP_HEADER="X-Real-IP"), ["real_ip_header X-Real-IP;"])

    def test_x_forwarded_for_restores_the_recursive_lookup(self):
        # For a reverse proxy of the operator's own that only appends X-Forwarded-For.
        self.assertEqual(
            self.real_ip_directives(EDGE_CLIENT_IP_HEADER="X-Forwarded-For"),
            ["real_ip_header X-Forwarded-For;", "real_ip_recursive on;"],
        )

    def test_unknown_client_ip_header_fails_closed(self):
        for value in ("x-real-ip", "X-Real-IP ", "Forwarded", "X-Forwarded-For; include /etc/passwd", "X-Real-IP\nserver_name x", "*"):
            with self.subTest(value=value):
                result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), EDGE_CLIENT_IP_HEADER=value)
                self.assertNotEqual(result.returncode, 0, value)
                self.assertIn("EDGE_CLIENT_IP_HEADER must be exactly X-Real-IP", result.stderr)
                self.assertFalse((self.conf / "nginx.conf").exists())

    def test_edge_proxy_override_accepts_a_cidr_list(self):
        result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), EDGE_PROXY_CIDRS="10.89.7.10/32, fd12::/16,100.64.0.0/10,2001:db8::1/128,1:2:3:4:5:6:7:8/128,::/1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.real_ip_sources(), [
            "set_real_ip_from 10.89.7.10/32;",
            "set_real_ip_from fd12::/16;",
            "set_real_ip_from 100.64.0.0/10;",
            "set_real_ip_from 2001:db8::1/128;",
            "set_real_ip_from 1:2:3:4:5:6:7:8/128;",
            "set_real_ip_from ::/1;",
        ])

    def test_edge_proxy_override_rejects_malformed_or_open_ranges(self):
        for value in (
            "10.0.0.0/8; include /etc/passwd",
            "10.0.0.0/8\nserver_name x",
            "0.0.0.0/0",
            "::/0",
            "10.0.0.0",
            "10.0.0.0/",
            "10.0.0/8",
            "10.0.0.0.0/8",
            "300.1.1.1/8",
            "10.0.0.0/33",
            "fd12::/129",
            "fd12:::1/64",
            "fd12::1::2/64",
            ":/64",
            "1:2:3/64",
            "12345::/64",
            ":1::/64",
            "1::2:/64",
            "1:2:3:4:5:6:7:8:9/64",
            "1:2:3:4:5:6:7::8/64",
            "*",
            ",",
        ):
            with self.subTest(value=value):
                result = self.run_start(JWT_SECRET=secrets.token_urlsafe(32), EDGE_PROXY_CIDRS=value)
                self.assertNotEqual(result.returncode, 0, value)
                self.assertIn("EDGE_PROXY_CIDRS must", result.stderr)
                self.assertFalse((self.conf / "nginx.conf").exists())

    def test_public_trader_data_requires_an_owner_session(self):
        source = START.read_text()
        gated = source.split("location ~ ^/api/(traders|competition|top-traders|equity-history|equity-history-batch|traders/[^/]+/public-config)/?$ {", 1)
        self.assertEqual(len(gated), 2, "public trader data location is missing")
        block = gated[1].split("}\n", 1)[0]
        self.assertIn("auth_request /_nofx_owner_session;", block)
        session = source.split("location = /_nofx_owner_session {", 1)[1].split("}\n", 1)[0]
        self.assertIn("internal;", session)
        self.assertIn("proxy_pass http://127.0.0.1:8081/api/my-traders;", session)
        # Regex locations are matched in order; the gate must precede the general /api/ prefix.
        self.assertLess(source.index("auth_request /_nofx_owner_session;"), source.index("location /api/ {"))

    def test_privileges_are_dropped_for_good(self):
        source = START.read_text()
        tail = source.split(MARKER, 1)[1]
        command = " ".join(tail.split("exec setpriv", 1)[1].replace("\\\n", " ").split())
        for flag in ("--reuid=\"$APP_USER\"", "--regid=\"$APP_USER\"", "--clear-groups", "--bounding-set=-all", "--no-new-privs"):
            self.assertIn(flag, command)
        self.assertTrue(command.endswith("/app/serve.sh"))
        self.assertIn("-exec chown -h", tail)
        self.assertNotIn("chown -R", tail)

    def test_backend_binds_loopback_only(self):
        source = SERVE.read_text()
        launch = [line for line in source.splitlines() if line.rstrip().endswith("/app/nofx &")]
        self.assertEqual(len(launch), 1)
        self.assertIn("NOFX_API_BIND_ADDRESS=127.0.0.1", launch[0])
        self.assertIn("NOFX_TRUSTED_PROXIES=127.0.0.1", launch[0])

    def test_generated_formats_and_permissions(self):
        result = self.run_serve()
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
        self.assertEqual(self.run_serve().returncode, 0)
        before = {p.name: p.read_bytes() for p in self.volume.iterdir()}
        self.assertEqual(self.run_serve().returncode, 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.volume.iterdir()})

    def test_supplied_keys_do_not_create_fallback_files(self):
        self.assertEqual(self.run_serve().returncode, 0)
        rsa = (self.volume / "rsa_private_key.pem").read_text()
        for path in self.volume.iterdir():
            path.unlink()
        result = self.run_serve(
            RSA_PRIVATE_KEY=rsa,
            DATA_ENCRYPTION_KEY=base64.b64encode(secrets.token_bytes(32)).decode(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.volume.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
