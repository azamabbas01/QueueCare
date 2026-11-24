# Supabase and app setup

See **README.md → Setup** for the short version. Details:

1. **Run the SQL** in *SQL Editor*: `backend/sql/schema.sql`, then `backend/sql/002_queuecare_v2.sql`. Both are idempotent.
   (If you use medical-record uploads, also run `medical_records_migration.sql` and `medical_records_uploader_index.sql`.)
2. **Auth settings**: Email provider on, *Confirm email* on, **TOTP MFA enabled**, JWT expiry 1800 s or less. Public sign-ups can stay enabled: anything created that way can only ever become a *patient*.
3. **Keys**: `SUPABASE_PUBLISHABLE_KEY` and the server-only `SUPABASE_SERVICE_ROLE_KEY` go in `backend/.env` only. Never put them in the Flutter app. Rotate any key that was ever committed or zipped.
4. **Storage**: buckets `medical-records` and `identity-photos` must be **private** (the migration creates the second).
5. **Email confirmation URL** (`AUTH_CONFIRMATION_URL`) must be the public API address ending in `/auth/confirm`, and the same URL must be allowed in *Auth → URL Configuration*.
6. **Create the first admin** on the server: `python scripts/create_admin.py --email … --name "…"` then sign in within 24 h to enrol the authenticator.
7. **Optional SMS**: set `TWILIO_*` in `.env`. Without them messages stay queued in `hq_sms_outbox`.
8. **Production**: set `ENVIRONMENT=production`, serve over HTTPS only, run the API behind a reverse proxy, and build the app with an `https://` `QUEUECARE_API_URL`.
