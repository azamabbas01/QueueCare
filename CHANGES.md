# What changed from the version you sent

## Security mistakes fixed
| Problem in the original | Fix |
|---|---|
| Anyone could choose Doctor / Staff / Admin when registering (pending approval for some) | Patient-only registration; role field removed and rejected; privileged accounts only via admin (staff/doctor/nurse) or server script (admin) |
| The **first account registered became Admin** | Removed |
| Admin accounts created by an admin could not sign in (profile stayed "pending / inactive") | Fixed: created accounts are active, with a forced password change |
| Admin login = email + password only | Mandatory TOTP authenticator, enforced by the API; idle timeout; lockout; audit trail |
| Login response and `/auth/me` returned internal columns (signup nonce, ID hash…) | Filtered |
| Doctor chart reads were not recorded | Audit log (fail-closed) |
| No emergency access path; doctors had no way to see an unassigned patient safely | Break-glass with reason, expiry, notification, admin review |
| Patient could mark their own turn as "no-show" and check themselves in from home | Removed; reception scans QR |
| Business-rule errors (queue full, duplicate booking) crashed with HTTP 500 | Clean 409 messages |
| `backend/.env` with a real service key shipped in the zip | Removed from package — **rotate the key** |
| `dashboard_shell.dart` — unused screen full of fake patients/doctors | Deleted |

## Workflow mistakes that made the app "unreal"
* The patient could not choose a time: the app silently booked the doctor's **first slot**. Now a real day + free-slot picker (`/doctors/{id}/slots`).
* A doctor could not complete a visit unless they called the next patient first. Now: *Call next → identity check → Start → notes → Complete*.
* Two patients could be "in the room" at once. Call-next now refuses until the current patient is finished or skipped.
* Queue position ignored urgency; wait time was a fixed guess. Now priority-aware, with estimates from real consultation lengths.
* The live queue never refreshed. It now updates automatically.
* Capacity was ignored for emergencies (a full day turned away a chest-pain walk-in); now emergencies bypass the quota.

## New screens and flows
Authenticator set-up/verify, forced password change, nurse triage, identity-photo capture/confirm, duplicate-patient dialog, QR scanner, consultation workspace, prescription builder, break-glass, security centre (audit, review, photo unlock), analytics, family members, prescriptions, visit summaries, feedback.

## Design
Logo applied (launcher icon, sign-in hero, app bars); palette taken from the logo; page transitions, staggered list entrance, press feedback, animated counters/bars/stepper/success screens; consistent loading / empty / error / content states; one feedback system (toast, OK, Yes/No, reason prompt).
