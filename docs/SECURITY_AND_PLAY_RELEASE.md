# QueueCare security and Google Play release

## Security clauses for the privacy notice

Publish and review these clauses with the hospital's legal/privacy contact before release. Replace the bracketed contact and retention details with the hospital's actual practices; do not publish placeholders.

1. **Information handled.** QueueCare handles account identifiers and profile details, appointment and queue information, and medical documents a patient chooses to upload. The hospital must identify every additional field collected by its deployment and disclose it in the Play Data safety form.
2. **Purpose and access.** Information is used to operate appointments and queues and to support authorized care workflows. Role checks and patient/appointment ownership checks restrict access. Staff and doctors receive only the records needed for their assigned workflow.
3. **Transmission and storage.** The Android release rejects non-HTTPS API endpoints and Android cleartext traffic is disabled. The backend keeps the Supabase server-only key outside the mobile app. QueueCare's database tables use row-level security and deny direct client grants; the API uses a server-side key only after validating the Supabase Auth session, account status, role, and ownership.
4. **Medical uploads.** The medical-records bucket is private. Uploads are size-limited, normalized, stripped of image metadata, and accessed through authenticated API routes. Do not use public storage URLs or expose the Supabase server key.
5. **Retention and deletion.** The hospital must state its actual retention period, backup lifecycle, and process for access/deletion requests here: **[hospital retention and deletion policy]**. Configure and test the corresponding operational process before accepting real patient records.
6. **Incident contact.** Privacy and security requests: **[hospital privacy/security contact]**. State the controller/operator identity, jurisdiction, and any legally required rights and timelines before publication.
7. **No absolute guarantee.** The hospital applies reasonable technical and organizational safeguards, but no internet-connected service can promise absolute security. Users should protect their credentials and report suspected account misuse to the hospital.

## Existing technical safeguards

- Supabase Auth handles passwords. The Flutter app receives a user access token and keeps it in memory only; sign-out and API `401` responses clear the local session.
- The Flutter client has no Supabase SDK, publishable key, or service-role key. The FastAPI service is the only database client.
- Queue tables have RLS enabled and no direct `anon`/`authenticated` grants. Server routes check role, active account, and ownership before using the privileged Supabase client.
- Signup, password reset, resend, and login have bounded API-side IP/email limits. Public responses avoid account-existence disclosure.
- Android release networking requires HTTPS, disables backup, and opts out of cleartext traffic. Release builds use R8/resource shrinking and can use a separately provisioned upload key.

## Release steps still requiring the hospital or Play Console

1. Deploy the FastAPI service at a stable HTTPS URL and build with `--dart-define=QUEUECARE_API_URL=https://<your-api-host>`. A release using the development default is blocked by the HTTPS check.
2. Rotate any Supabase server key that may have been exposed in an earlier project artifact. Store its replacement only in the backend secret manager/environment; do not inspect or copy local `.env` values into Flutter or source control.
3. Set exact production `CORS_ORIGINS`, trusted proxy configuration, gateway-level rate limits, upload/request size limits, database backups, monitoring, and a tested incident-response process. The built-in limiter is process-local and must not be the only production limit.
4. Provision an upload keystore in a protected secret store. Set `QUEUECARE_UPLOAD_KEYSTORE`, `QUEUECARE_UPLOAD_STORE_PASSWORD`, `QUEUECARE_UPLOAD_KEY_ALIAS`, and `QUEUECARE_UPLOAD_KEY_PASSWORD` in the release build environment. Keep the key and passwords out of the repository and backups accessible to app users.
5. Confirm the application ID `com.queuecare.hospitalqueue` is available to the publisher; replace it before first release if the hospital owns a different namespace. Keep it unchanged after publishing.
6. Publish a public privacy-policy URL based on the clauses above, with real operator, contact, retention, sharing, and deletion details. Complete Play Console's Data safety, health-app declaration, content rating, target audience, and app access/reviewer instructions truthfully.
7. Provide a Play app icon and store listing assets, a support contact, and reviewer credentials/test path. Verify the email confirmation callback and `queuecare://auth/signin` link with the production domain and real test accounts.
8. Build a signed Android App Bundle (`flutter build appbundle --release --dart-define=QUEUECARE_API_URL=https://<your-api-host>`), then review the Play pre-launch report and test on supported Android devices before rollout.

New Google Play Android apps and updates must target API 36 or higher from August 31, 2026. This Android scaffold targets API 36. Play submission still depends on the publisher completing the account, listing, policy, signing, and privacy disclosures above.

## Supabase deployment boundary

The mobile app connects to the QueueCare FastAPI API, not directly to Supabase. The API validates Supabase Auth tokens and reads the server-only database key from backend environment configuration. Apply and verify `backend/sql/schema.sql` (or the documented migrations) in the intended Supabase project before deployment. The local `.env` file is ignored by Git and is not a mobile configuration source.
