# V1.3 Spec: identity, bus card, stop alerts, pickup decisions

Authoritative brief for the V1.3 work (server migrations 0011/0012 + Flutter). Read with `CLAUDE.md` conventions
(`/api/v1`, snake_case, UUIDs, error envelope, thresholds are config, role loaded from DB). Agents write the FINAL
endpoint contracts into `docs/v1/server-contract.md` (the Flutter agents read that file, not this one, for shapes).

## Decisions (made; do not re-litigate)
1. **Students cannot delete their account.** `DELETE /me` is refused for students (403 `FORBIDDEN`). They request
   deregistration (`POST /me/deregistration-request`); an admin approves (account + data deleted, audited) or rejects.
2. **Route is chosen once at registration and is locked** for the student (admin can reassign). The student app has NO route
   switcher; a student only ever sees their own route and its buses.
3. **Approval auto-assigns a bus.** `POST /admin/students/{id}/approve` accepts an OPTIONAL `bus_id`. Without it: the bus
   matching `requested_bus_label` (case-insensitive label or plate) if it serves the student's route and has a free seat;
   else the serving bus with the most free seats; else 409 `NO_SEAT`. With `bus_id`: current manual behaviour. Manual
   reassign stays. "Serves a route" = bus default route or any route its driver is assigned to (V1.2 rule).
4. **Registration fields (all required):** full name, phone, department, **enrollment number**, **home address**, route,
   **passport-style face photo**. Optional: requested bus label. No ML face detection: the app guides the framing (oval
   overlay, 3:4 crop, compress to JPEG <= 200 KB, ~600 px high); the admin reviews the photo on approval.
5. **Photos live in Postgres (`bytea`)**, served only by authenticated endpoints (never public URLs, never in lists):
   student photo -> the student, admins, the driver of the bus the student is assigned to or has a pending decision with;
   driver photo -> the driver, admins, students assigned to that bus.
6. **Digital bus card.** Issued only to approved students. Server signs the card payload with HMAC-SHA256 (key derived from
   the server secret; "digitally signed by the Administration, University of Kashmir" is shown with the seal, and the QR
   carries `payload.signature`). `GET /bus-card/verify?token=` (public, rate-limited) returns only
   `{valid, name, bus_label, valid_until}`; never the photo, phone or address. Validity end date is a setting.
7. **Students see only the first and last stop** of their route (server filters stops for the student role) plus the full
   route line and the real map (nearby places come from the Google map base layer, not a Places API). They add one
   **pickup marker** on the route line (existing pickup pins); ETAs are to that marker (or to the first stop when none).
8. **Stop alert.** A trip whose bus has not moved for `stopped_alert_after_s` (settings, default 300) triggers: (a) the
   trip status auto-becomes `delayed` with note "Stopped" if it was `on_time` (students see it live), (b) a push + in-app
   prompt to the DRIVER to say why. Reasons: `waiting_for_student`, `traffic`, `breakdown`, `fuel`, `police_check`,
   `other` (+ note <= 140 chars). The reason updates trip status/note for students. Driver can **snooze** (15/30/60 min) or
   **opt out** of these driver prompts (`driver_prefs`); the auto status for students still applies. When the bus moves
   again the auto "Stopped" status clears back to `on_time` (a driver-set reason stays until the driver changes it).
9. **Pickup requests from students not assigned to the trip's bus** (approved on the route, other bus) are `needs_decision`:
   the driver gets a push "Unknown student wants a pickup", sees the student card (photo, name, department, enrollment) and
   accepts or rejects; the student sees the decision. Students assigned to the bus are accepted automatically (existing).
10. **Driver can only start a journey** (no schedule/route admin). Starting anywhere mid-route works: live location and ETA
    follow the first fix, never assume the bus began at stop 1. Driver sees their own profile (name, phone, photo, employee
    id, licence number/expiry, bus) and the roster of students on their bus with photo/enrollment/department.
11. **Students can see their bus and driver card** (bus label, plate, driver name, phone, photo) to contact the driver.
12. **Admin** sees a students table (name, email, enrollment, department, route, bus, status) and opens a full detail page
    on tap (address, photo, phone, everything, deregistration state, approve/reject/reassign). Admin also handles
    deregistration requests.
13. Bug fixes in scope: driver status/delay not reaching students live (find root cause, add a regression test); student
    route switching removed.

## Data model (additive, forward-only)
- `0011_identity_card.sql`: `student_profiles` += `enrollment_no text`, `home_address text`, `photo bytea`, `photo_mime text`,
  `photo_updated_at timestamptz`; `driver_profiles` += `photo bytea`, `photo_mime text`, `photo_updated_at timestamptz`;
  `deregistration_requests (id uuid pk, user_id uuid fk cascade, reason text, status text check in
  ('pending','approved','rejected'), admin_note text, created_at, reviewed_by uuid, reviewed_at)` with one pending per user;
  settings keys `bus_card_valid_until` (ISO date, default next 31 July) etc.
- `0012_stop_alerts_pickup_decisions.sql`: `stop_events (id, trip_id fk, started_at, ended_at, reason text, note text,
  auto_marked bool, driver_notified_at)`; `driver_prefs (user_id pk fk, stop_alerts_enabled bool default true,
  snooze_until timestamptz)`; pickups += `decision text check in ('auto','needs_decision','accepted','rejected')` default
  'auto' + `decided_at`; settings key `stopped_alert_after_s` = 300.
Both files and their Alembic wrappers already exist as no-op placeholders: fill them, do not renumber.

## Work packages and ownership
| Pkg | Agent | Files it owns |
|---|---|---|
| S-A | server identity | migration 0011; `server/app/modules/{students,me,auth,admin/drivers}`, new `modules/buscard`, tests |
| S-B | server ops | migration 0012; `server/app/modules/{trips,pickups,tracking,eta,routes}`, `app/jobs`, `app/live`, push, tests |
| F-S | flutter student | `app/lib/features/student/**` + student tests |
| F-D | flutter driver + admin | `app/lib/features/{driver,admin}/**` + tests |
Shared files (`server/app/api/router.py`, `server-contract.md`, `core/models/*`): minimal line edits only; re-read before editing.
