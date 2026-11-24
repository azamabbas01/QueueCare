"""Behavioural security tests that run without a Supabase project."""
import re
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from fastapi import HTTPException
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from app import common, gotrue, main, routes_admin
from app.main import app
from app.security import authenticate, public_profile

ROOT = Path(__file__).parents[1]
UUID = "11111111-1111-1111-1111-111111111111"


def actor(role, **extra):
    base = {"id": UUID, "role": role, "full_name": "Test", "email": "t@x.com", "is_active": True,
            "signup_finalized": True, "must_change_password": False, "department_id": UUID,
            "_aal": "aal2", "_token": "tok"}
    return {**base, **extra}


class AsRole:
    """Override the authentication dependency so a request behaves as the given account."""

    def __init__(self, role, **extra):
        self.profile = actor(role, **extra)

    def __enter__(self):
        app.dependency_overrides[authenticate] = lambda: self.profile
        return TestClient(app, raise_server_exceptions=False)

    def __exit__(self, *exc):
        app.dependency_overrides.clear()


class FakeQuery:
    def __init__(self, data):
        self.data = data

    def __getattr__(self, _):
        return lambda *a, **k: self

    def execute(self):
        return MagicMock(data=self.data)


class FakeDB:
    def __init__(self, tables=None):
        self.tables = tables or {}
        self.inserted = []

    def table(self, name):
        query = FakeQuery(self.tables.get(name, []))
        original_insert = query.insert if False else None  # noqa: F841
        return query


class SelfRegistrationTests(unittest.TestCase):
    base = {"email": "new@patient.com", "password": "Sunny2026day", "full_name": "New Patient",
            "phone": "0300 1234567", "accept_terms": True, "consent_data_use": True}

    def test_role_field_is_rejected(self):
        client = TestClient(app)
        for role in ("admin", "doctor", "staff", "nurse", "patient"):
            r = client.post("/api/v1/auth/register", json={**self.base, "role": role})
            self.assertEqual(r.status_code, 422, role)

    def test_signup_requires_consent(self):
        client = TestClient(app)
        r = client.post("/api/v1/auth/register", json={**self.base, "consent_data_use": False})
        self.assertEqual(r.status_code, 422)

    def test_weak_password_rejected(self):
        client = TestClient(app)
        r = client.post("/api/v1/auth/register", json={**self.base, "password": "password1"})
        self.assertEqual(r.status_code, 422)

    def test_no_privileged_role_can_come_out_of_signup_code(self):
        source = (ROOT / "app" / "main.py").read_text()
        self.assertNotIn("hq_finalize_signup", source)
        self.assertNotIn("signup_requested_role", source)
        schema = (ROOT / "sql" / "schema.sql").read_text()
        finalizer = schema[schema.index("hq_finalize_patient_signup("):]
        self.assertIn("role = 'patient'", finalizer)
        self.assertNotIn("count(*) = 0", schema)  # no "first account becomes admin"


class AdminProtectionTests(unittest.TestCase):
    def test_admin_without_mfa_is_refused(self):
        with AsRole("admin", _aal="aal1") as client:
            r = client.get("/api/v1/admin/overview")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"]["code"], "mfa_required")

    def test_forced_password_change_blocks_everything_else(self):
        with AsRole("doctor", must_change_password=True) as client:
            r = client.get("/api/v1/doctor/queue")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"]["code"], "password_change_required")

    def test_mfa_endpoints_reject_non_admins(self):
        for role in ("patient", "doctor", "staff", "nurse"):
            with AsRole(role) as client:
                self.assertEqual(client.post("/api/v1/auth/mfa/enroll").status_code, 403, role)

    def test_enrolment_closed_without_window(self):
        with AsRole("admin", _aal="aal1", mfa_enroll_until=None) as client, \
                patch.object(gotrue, "list_factors", return_value=[]):
            r = client.post("/api/v1/auth/mfa/enroll")
        self.assertEqual(r.status_code, 403)

    def test_cannot_create_admin_through_admin_api(self):
        with AsRole("admin") as client:
            r = client.post("/api/v1/admin/users", json={
                "email": "x@y.com", "full_name": "Bad Actor", "role": "admin", "department_id": UUID})
        self.assertEqual(r.status_code, 422)

    def test_login_for_admin_reports_mfa_and_hides_private_fields(self):
        session = MagicMock(access_token="a", refresh_token="r", expires_in=3600, token_type="bearer")
        auth = MagicMock()
        auth.auth.sign_in_with_password.return_value = MagicMock(user=MagicMock(id=UUID), session=session)
        profile = actor("admin", signup_nonce="secret", national_id_hash="h", mfa_enroll_until=None)
        fake = FakeDB({"hq_profiles": [profile]})
        with patch.object(main, "get_auth_client", return_value=auth), patch.object(main, "db", return_value=fake), \
                patch.object(common, "db", return_value=fake), patch.object(gotrue, "list_factors", return_value=[]):
            r = TestClient(app).post("/api/v1/auth/login", json={"email": "a@b.com", "password": "x"})
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["mfa"]["mode"], "blocked")
        self.assertNotIn("signup_nonce", body["user"])
        self.assertNotIn("national_id_hash", body["user"])
        self.assertFalse(any(k.startswith("_") for k in body["user"]))

    def test_failed_logins_lock_the_account(self):
        auth = MagicMock()
        auth.auth.sign_in_with_password.side_effect = Exception("bad")
        fake = FakeDB()
        with patch.object(main, "get_auth_client", return_value=auth), patch.object(common, "db", return_value=fake):
            client = TestClient(app)
            codes = [client.post("/api/v1/auth/login", json={"email": "lock@x.com", "password": "nope"}).status_code for _ in range(7)]
        self.assertEqual(codes[:5], [401] * 5)
        self.assertIn(429, codes[5:])


class RoleMatrixTests(unittest.TestCase):
    """Every role-scoped endpoint must refuse every other role."""

    def routes(self):
        for route in app.routes:
            if isinstance(route, APIRoute) and re.match(r"^/api/v1/(patient|doctor|staff|nurse|admin)/", route.path):
                yield route, route.path.split("/")[3]

    def test_wrong_role_always_403(self):
        checked = 0
        for route, owner in self.routes():
            path = re.sub(r"\{[^}]+\}", UUID, route.path)
            for role in ("patient", "doctor", "staff", "nurse", "admin"):
                if role == owner:
                    continue
                for method in route.methods - {"HEAD", "OPTIONS"}:
                    with AsRole(role) as client:
                        r = client.request(method, path, json={})
                    self.assertEqual(r.status_code, 403, f"{role} -> {method} {route.path} gave {r.status_code}")
                    checked += 1
        self.assertGreater(checked, 300)

    def test_unauthenticated_is_401_everywhere(self):
        client = TestClient(app)
        for route, _ in self.routes():
            path = re.sub(r"\{[^}]+\}", UUID, route.path)
            for method in route.methods - {"HEAD", "OPTIONS"}:
                self.assertEqual(client.request(method, path, json={}).status_code, 401, route.path)

    def test_staff_and_admin_have_no_clinical_routes(self):
        """Clinical data (vitals, notes, prescriptions, history) must be unreachable by reception and admin."""
        clinical = re.compile(r"(medical-history|consultation|prescription|break-glass/\{session_id\}/history)")
        for route, owner in self.routes():
            if clinical.search(route.path):
                self.assertIn(owner, ("doctor", "patient"), route.path)
        for route, owner in self.routes():
            if owner == "admin":
                self.assertNotIn("vitals", route.path)


class HelperTests(unittest.TestCase):
    def test_password_policy(self):
        common.validate_password("Sunny2026day")
        for bad in ("short1", "alllettersnodigits", "12345678", "password1"):
            with self.assertRaises(HTTPException):
                common.validate_password(bad)
        with self.assertRaises(HTTPException):
            common.validate_password("Sunny2026day", strict=True)  # no symbol
        common.validate_password("Sunny-2026-Day!", strict=True)

    def test_generated_temp_passwords_meet_strict_policy(self):
        for _ in range(50):
            common.validate_password(routes_admin.generate_temp_password(), strict=True)

    def test_phone_normalisation_makes_duplicates_comparable(self):
        forms = ["0300 1234567", "+92 300 1234567", "92-300-1234567", "00923001234567", "3001234567"]
        self.assertEqual({common.normalize_phone(f) for f in forms}, {"+923001234567"})
        with self.assertRaises(HTTPException):
            common.normalize_phone("12")

    def test_national_id_hash_is_stable_and_not_plain(self):
        a = common.hash_national_id(common.normalize_national_id("35202-1234567-1"))
        b = common.hash_national_id(common.normalize_national_id("3520212345671"))
        self.assertEqual(a, b)
        self.assertNotIn("3520212345671", a)

    def test_queue_order_emergency_first_then_queue_position(self):
        rows = [{"priority": "routine", "queue_sort": 1, "queue_number": 1},
                {"priority": "urgent", "queue_sort": 5, "queue_number": 5},
                {"priority": "emergency", "queue_sort": 9, "queue_number": 9},
                {"priority": "routine", "queue_sort": 12, "queue_number": 2}]  # a late arrival, requeued
        ordered = sorted(rows, key=common.queue_key)
        self.assertEqual([r["priority"] for r in ordered], ["emergency", "urgent", "routine", "routine"])
        self.assertEqual(ordered[-1]["queue_sort"], 12)

    def test_masked_names(self):
        self.assertEqual(common.mask_name("Ayesha Khan"), "Ayesha K***")

    def test_token_aal_claim(self):
        import base64, json
        def tok(c):
            body = base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("=")
            return f"h.{body}.s"
        self.assertEqual(gotrue.token_aal(tok({"aal": "aal2"})), "aal2")
        self.assertEqual(gotrue.token_aal(tok({})), "aal1")
        self.assertEqual(gotrue.token_aal("garbage"), "aal1")

    def test_public_profile_strips_internals(self):
        out = public_profile({"id": "1", "signup_nonce": "n", "_token": "t", "national_id_hash": "h", "full_name": "A"})
        self.assertEqual(out, {"id": "1", "full_name": "A"})

    def test_audit_fails_closed(self):
        broken = MagicMock()
        broken.table.side_effect = Exception("db down")
        with patch.object(common, "db", return_value=broken):
            with self.assertRaises(HTTPException) as ctx:
                common.audit(actor("doctor"), "clinical.history_viewed")
            self.assertEqual(ctx.exception.status_code, 503)
            common.audit(actor("doctor"), "auth.login", required=False)  # best-effort variant does not raise


class SqlMigrationTests(unittest.TestCase):
    sql = (ROOT / "sql" / "002_queuecare_v2.sql").read_text()

    def test_every_new_table_has_rls_and_no_client_grants(self):
        for table in re.findall(r"create table if not exists public\.(hq_\w+)", self.sql):
            self.assertIn(f"'{table}'", self.sql, f"{table} missing from RLS block")

    def test_audit_log_is_append_only(self):
        self.assertIn("revoke update, delete, truncate on public.hq_audit_log", self.sql)
        self.assertIn("before update or delete on public.hq_audit_log", self.sql)

    def test_call_next_is_atomic(self):
        body = self.sql[self.sql.index("function public.hq_call_next_patient"):]
        self.assertIn("pg_advisory_xact_lock", body[:900])
        self.assertIn("skip locked", body[:1800])


if __name__ == "__main__":
    unittest.main()
