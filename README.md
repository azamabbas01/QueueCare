# QueueCare — hospital queue and clinical workflow app

Flutter app (Android) + FastAPI backend + Supabase (Postgres, Auth, private Storage).

| Role | What they do |
|---|---|
| **Patient** | Registers themselves, books a real time slot, tracks the live queue with an estimated wait, keeps records, family members, prescriptions, bilingual visit summaries |
| **Reception (staff)** | Scans the patient's QR to check in, registers walk-ins (with duplicate detection and consent), captures and confirms identity photos |
| **Nurse** | Records triage vitals and sets priority |
| **Doctor** | Calls patients in priority order, checks identity photo, writes notes (typed or dictated), prescriptions, follow-ups, referrals; emergency (break-glass) access |
| **Administrator** | Creates all staff accounts, departments and queue rules, reviews break-glass access, reads the audit log, sees de-identified analytics. Protected by an authenticator app (TOTP) |

## Who can create which account

* **Only patients can register in the app.** The registration form and API have no role field; a request that includes one is rejected, and the database function that finishes sign-up can only ever produce a patient.
* **Doctor, nurse and reception accounts are created only by an administrator** (People → New account). The server generates a strong temporary password, shown once; the person must change it at first sign-in.
* **Administrator accounts are created only on the server** with `backend/scripts/create_admin.py`. They cannot be created through the app or the API, so a stolen session can't mint admins.
* The old behaviour where the **first person to register became admin** has been removed.

## Setup (about 15 minutes)

1. **Supabase**: create a project. In *SQL Editor* run, in this order:
   1. `backend/sql/schema.sql`
   2. `backend/sql/002_queuecare_v2.sql`  (safe to re-run)
   In *Authentication → Providers → Email* keep **Confirm email** on. In *Authentication → Multi-Factor* make sure **TOTP** is enabled. Under *Authentication → Sessions* set a short JWT expiry (e.g. 1800 s).
   The migration creates the private `identity-photos` bucket. The `medical-records` bucket comes from the earlier `medical_records_migration.sql` files if you use those uploads.
2. **Backend**
   ```bash
   cd backend
   python -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt
   cp .env.example .env     # fill in the three Supabase values + NATIONAL_ID_PEPPER
   uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
3. **First administrator** (on the server):
   ```bash
   python scripts/create_admin.py --email owner@hospital.org --name "Full Name"
   ```
   Then sign in to the app within 24 h: you will be shown a QR code to scan with an authenticator app (Google/Microsoft Authenticator, Aegis…). Lost the phone? `--reopen-mfa` on the server reopens setup.
4. **Flutter app** (Flutter 3.27 or newer)
   ```bash
   flutter pub get
   flutter run --dart-define=QUEUECARE_API_URL=http://10.0.2.2:8000     # Android emulator
   # release builds require HTTPS:  --dart-define=QUEUECARE_API_URL=https://api.your-hospital.org
   ```
5. As admin: create a department's doctors, a nurse and a receptionist, set the doctors' weekly hours (People → tap a doctor → *Set weekly hours*). Patients can then book.

> **Secrets:** the original zip contained a `backend/.env` with a real Supabase service-role key. It has been removed from this package. **Rotate that key in the Supabase dashboard** (Project Settings → API) and never commit `.env`.

## Messages and notifications (how the app talks to people)

| Kind | Used for | Look |
|---|---|---|
| **Toast** (auto-dismiss, optional action such as *Retry*) | Quick results: "Booking confirmed", "Notes saved" | Slim navy card, coloured edge (green success / blue info / amber warning / red error), haptic tap |
| **OK dialog** | Something that must be read: "It's your turn", credentials shown once | One button |
| **Yes / No dialog** | Any decision: sign out, cancel visit, check in, deactivate account, lock a photo. Risky ones are red | Two buttons, labelled with the action ("Yes, cancel visit" / "No, keep it") |
| **Reason prompt** | Emergency priority, break-glass, referrals, unlocking a photo | Text box + Submit / Cancel; Submit stays disabled until the reason is long enough |
| **Notice card** | Persistent in-page information and errors | Tinted card with icon |
| **Notifications** | In-app list with bell badge, plus **SMS fallback** for "3 patients before you", "You're almost next" and "Follow-up recommended" | |

Every screen handles four states: **loading** (animated skeleton), **content** (staggered fade-in), **empty** (friendly panel with an action) and **error** (message + *Try again*).

## Feature coverage (against *Hospital_Queue_App_Scope_and_Features.docx*)

**Built and tested** — Section 1 & 2 (must-have), most of Section 3:

| Item from the document | Status |
|---|---|
| Postgres RLS / private buckets / clinical data separate from admin data | ✅ All tables RLS-on with no client policy; vitals, notes, prescriptions, follow-ups live in their own tables; admin has no clinical endpoints (enforced by a test) |
| Fifth role (nurse) for vitals | ✅ |
| Admin sees scheduling + de-identified analytics only; doctor sees only assigned patients | ✅ |
| Live tracker carries no patient data | ✅ token numbers only |
| Atomic "Call Next" | ✅ one Postgres function: advisory lock + `SKIP LOCKED`; refuses while a patient is still with the doctor |
| Break-glass | ✅ reason ≥ 15 chars, 30-min expiry, patient + admins notified, admin review queue, 10/day cap; security-definer function |
| Audit log (append-only) | ✅ reads of clinical data, calls, break-glass, logins, admin actions; clinical reads fail closed if the log can't be written; UPDATE/DELETE/TRUNCATE blocked even for the service role |
| Photo identity check | ✅ shown to doctor on Call Next; reception confirms against ID → locked; admin-supervised unlock with recorded reason |
| Triage priority (emergency / urgent / routine) with visible reason | ✅ reorders the queue; emergencies bypass the daily quota |
| Duplicate patient detection (phone, national ID) | ✅ at registration and at walk-in (link to existing or confirm new) |
| No-show / recall rules | ✅ grace timer, skip & recall (max 2), late arrivals requeued to the back |
| Consent capture (photo, data use) | ✅ stored with policy version |
| Real wait estimates from actual consultation durations | ✅ per doctor, last 30 visits |
| Notifications with SMS fallback | ✅ in-app + SMS outbox (Twilio-compatible; stays queued until credentials are set) |
| Dependent profiles | ✅ |
| Prescriptions (doctor-written, patient-viewable, PDF, hidden from staff) | ✅ |
| Visit summary in English and Urdu + follow-up instructions | ✅ |
| Follow-up booking | ✅ doctor picks a date → patient books in one tap |
| Multi-stage journey | ✅ Booked → Checked in → Triage → Consultation → Done (stepper) |
| Doctor handoff / referral | ✅ moves to the other doctor's queue; access moves with it |
| Voice dictation + visit templates | ✅ device speech recognition (English / Urdu) |
| Admin analytics (wait, no-show, peak hours, doctor load) | ✅ de-identified |
| "Transcript" meaning | Implemented as **typed or dictated text** (no audio is recorded or stored), as the document recommends for v1 |

**Not built (be upfront with your teacher):**
* **Push notifications (FCM).** The app polls every 10–15 s and SMS covers phones without data; true push needs a Firebase project.
* **Lab / pharmacy stages and the waitlist.** The journey stepper stops at consultation → done (the document lists these as v2).
* **Urdu for the whole interface.** Visit summaries and instructions are bilingual; menus and buttons are English.

## Security highlights

* One sign-in form for every role; the server decides the dashboard (no role picker to attack).
* Admin API refuses any token that has not completed TOTP (checked from the verified token's `aal2` claim). Authenticator set-up can only be started inside a 24-hour window opened on the server, so knowing an admin's password is not enough to attach an attacker's authenticator.
* Failed-login lockout (5 tries / 15 min per account), per-IP and per-email rate limits, MFA attempt limits.
* Passwords: patients 8+ chars (letters + numbers); staff and admins 12+ with mixed case and a symbol; common passwords refused.
* Admin-issued passwords must be changed at first sign-in; resets and deactivation (which also bans the Auth user so refresh tokens stop working).
* Short idle sign-out (admin 10 min, clinical staff 20 min, patients 45 min); silent token refresh; automatic return to sign-in when a session ends.
* National ID numbers are stored only as a salted HMAC (plus last 4 digits for display).
* Android: screenshots/screen recording and the recent-apps preview are blocked (`FLAG_SECURE`); release builds require HTTPS; tokens are kept in memory only.
* API: security headers, no-store caching, docs disabled in production, strict CORS.
* Patients can no longer check themselves in from home (queue-jumping); reception scans the QR.

## Tests

```bash
cd backend && pip install -r requirements-dev.txt && python -m pytest tests -q
```
29 tests, including a matrix that calls **every** role-scoped endpoint as every other role (300+ combinations, all must be refused) and checks that unauthenticated calls get 401. The SQL (schema + migration) was also executed against a real PostgreSQL 16 and exercised end to end: priority ordering, double-call prevention, late requeue, skip/recall, referral, break-glass notifications, audit immutability, photo lock/unlock, and the patient-only sign-up function.

> The Flutter code was syntax-checked with the Dart SDK but could not be compiled here (no Flutter SDK in the build sandbox). Run `flutter pub get && flutter analyze` first; any remaining findings should be small (imports/typos), not structural.

More detail: `CHANGES.md`, `SUPABASE_SETUP.md`, `docs/`.
