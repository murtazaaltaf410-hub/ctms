# CTMS V1 — Test matrix (Phase 6)

Maps every test case (TC1–TC20), every edge case in the catalogue (T, N, EC-A, U) and every launch-gate and field-test item to the tests that cover it, or to the owner who will cover it. Paths are relative to `server/tests/`. IDs follow `requirements-matrix.md`: **EC-A** marks alert edge cases, to keep them apart from PRD admin features.

**Status values:**
- **pass**: automated and green at the Phase 6 commit.
- **xfail-bug**: a strict xfail that documents an open server bug (see *Open bugs*).
- **app (P7/P8)**: the remaining behaviour lives in the Flutter app.
- **field (manual)**: only a real phone on a real bus can prove it.
- **ops (P9/P10)**: deployment, configuration or process.

A row can carry two statuses. For example, "pass / app" means the server side is automated and the UI side is owned by the app.

**How to run:**
- Everything: `cd server && uv run ruff check . && uv run pytest -q`
- Acceptance suite only: `uv run pytest -q tests/acceptance`

The acceptance tests drive the real API through `httpx.ASGITransport` against the test Postgres. They generate fix streams with the simulator core (`server/scripts/simulate.py`) and move the injected clock (`app/clock.py`) instead of sleeping.

## Test cases TC1–TC20

| ID | Test (test plan p.2–3) | Acceptance test (`tests/acceptance/`) | Unit / API tests (P2–P5) | Status |
|---|---|---|---|---|
| TC1 | Google sign-in: university and non-university accounts both succeed as students (U1) | `test_tc01_google_sign_in.py` | `test_auth.py::test_tc1_google_sign_in_university_and_personal_accounts` | pass / app (sign-in screen) |
| TC2 | Unregistered phone requests an OTP: same response, no OTP sent | `test_tc02_otp_uniform.py` | `test_auth.py::test_tc2_unregistered_phone_gets_identical_response` | pass |
| X2 | `test_pickups_api.py`: pin near the route, too far / unknown route / bad input → 400, one waiting pin (replace), cancel own pin only, expiry, driver list without student identity, role and ownership checks, account delete removes the pin | pass |
| X3 | `test_pickup_alerts.py`: driver + student push once per (pin, trip) on approach, none when moving away, no second student push when the nearby-bus alert fired, picked_up when passed, other leg / expired pins ignored | pass |
| TC3 | Driver signs in on a second phone; the first gets SESSION_REPLACED (T11) | `test_tc03_session_replaced.py` (mid-trip, simulator continues on phone 2) | `test_auth.py::test_tc3_second_phone_replaces_first_session`, `test_ws_live.py::test_revoked_session_socket_is_closed` | pass / app (signed-out screen) |
| TC4 | Student → admin endpoint 403 FORBIDDEN_ROLE; driver → another's trip 403 NOT_YOUR_TRIP | `test_tc04_roles.py` (12 admin endpoints × student and driver; locations/status/end on another's trip) | `test_trips.py::test_not_your_trip_is_403`, `test_buses_admin.py::test_non_admin_is_forbidden` | pass |
| TC5 | Start a trip twice: 409 TRIP_ALREADY_ACTIVE (T10) | `test_tc05_trip_twice.py` (resume through `GET /trips/active`, end, restart; bus in use by a substitute) | `test_trips.py::test_tc5_second_start_is_409`, `::test_tc5_concurrent_start_hits_unique_index` | pass / app (resume or end dialog) |
| TC6 | 80 m accuracy fix and a 200 km/h fix: both rejected with reasons, last good position kept (T3, T4) | `test_tc06_bad_fixes.py` (simulator `bad_accuracy_every` / `spike_every`; live position checked after every upload) | `test_tracking.py::test_tc6_bad_accuracy_and_speed_rejected_last_good_kept` | pass |
| TC7 | Same fix_id twice: one stored (N6) | `test_tc07_duplicates.py` (in-batch duplicates and whole-batch retries, before and after the writer flush) | `test_tracking.py::test_tc7_same_fix_id_twice_stored_once` | pass |
| TC8 | 2 min without fixes: stale at 30 s, offline at 2 min (T5) | `test_tc08_stale_offline.py` (29/30/119/120 s on `/buses/live` and the ETA state; live again on the next fix; receive time, not phone time) | `test_live_state.py::test_tc8_stale_at_30s_offline_at_2min` | pass / app (styling) |
| TC9 | Driver offline 3 min: buffered fixes upload in order; map catches up (T6) | `test_tc09_offline_buffer.py` (3-min dropout → batches of ≤20 at reconnect; history complete and ordered; live jumps to the newest fix; not auto-closed; backlog arriving out of order is history only) | `test_tracking.py::test_t6_t12_buffered_and_late_fixes_fill_history_only` | pass (server) / app (P8 sqflite buffer) / field (FT-D6) |
| TC10 | Student app open while the simulator drives: marker moves within 5 s of each fix | `test_tc10_live_latency.py` (every upload → `bus_position` in the same request; newest fix ≤5 s old at publish; `/buses/live` agrees) | `test_ws_live.py::test_ping_pong_and_broadcasts` | pass (server) / app (marker animation) / field (FT-D1) |
| TC11 | Kill and restore the student's connection: banner, reconnect, correct positions (N2) | `test_tc11_reconnect.py` (no replay on reconnect; `/buses/live` refetch is correct; a trip that ended while disconnected is gone) | `test_ws_live.py` | pass (server) / app (P7 banner, backoff) |
| TC12 | Bus at known distances and speeds: ETA within 5 % of the formula | `test_tc12_eta.py` (15/30/45 km/h past a corner; v_min floor; EC-A9 cap) | `test_eta.py::test_tc12_eta_matches_formula_within_5_percent` | pass |
| TC13 | Bus approaches a student at 600, 500 and 400 m: one alert near 500 m, never repeated | `test_tc13_alert_approach.py` (literal 600/500/400; realistic road approach; far and opted-out students; next trip alerts again) | `test_alerts.py::test_tc13_approach_600_500_400_sends_exactly_one_alert` | pass |
| TC14 | Bus moving away inside 500 m, or student riding the bus: no alert (EC-A3, EC-A1) | `test_tc14_away_and_rider.py` (moving away; idealised rider; rider with 100 m move-reporting) | `test_alerts.py::test_tc14_a3_bus_moving_away_inside_radius_no_alert`, `::test_tc14_a1_student_riding_the_bus_is_suppressed` | pass |
| TC15 | Student denies background location or notifications: clear message, no silent failure (EC-A6, EC-A7) | `test_tc15_permissions.py` (no push token → 400 with reason; approximate or old location → 400; EC-A5 stale location → no alert; invalid token deleted and alert listed in-app) | `test_alerts_api.py::test_enabling_alerts_requires_a_push_token` | pass (server) / app (P8 permission flows) |
| TC16 | Create a route with stops while Directions fails: draft with POLYLINE_FAILED (U7) | `test_tc16_polyline_failed.py` (cannot activate, not public, cannot start a trip; regenerate fixes it; a failing stop add turns the route into a draft) | `test_routes_admin.py::test_tc16_routes_api_failure_saves_draft` | pass |
| TC17 | Delete a route during an active trip; remove the last admin: both blocked (U5, U6) | `test_tc17_blocked_deletes.py` (route, stop and bus → IN_USE mid-simulation; soft delete after the trip; LAST_ADMIN) | `test_routes_admin.py::test_tc17_u6_route_and_stop_in_use`, `test_admin_admins.py::test_u5_last_admin_cannot_remove_self` | pass; **U6 ETA part: xfail-bug P6-1** |
| TC18 | Three simulated trips: distance and times match the simulator's totals within 2 % | `test_tc18_reports.py` (3 trips, 2 buses, one with faults and a dropout; trip list, summary and CSV) | `test_reports_admin.py::test_tc18_trip_list_distance_and_times` | pass |
| TC19 | Restart the server mid-trip: the trip continues and the map recovers within one fix (N4) | `test_tc19_restart.py` (with and without the startup rebuild; final distance within 2 %) | `test_live_state.py::test_tc19_restart_mid_trip_rebuilds_from_db` | pass |
| TC20 | Delete a student account: location, push token and alert log gone (U2) | `test_tc20_delete_account.py` (mid-trip, after an alert; no alert on the next trip; audit log scrubbed) | `test_me.py::test_tc20_delete_student_removes_personal_data`, `test_alerts.py::test_u2_deleting_account_stops_alerts` | pass |
| E2E | Admin creates a route → bus and driver → trip → alert, WS, ETA → end → report and CSV | `test_e2e_scenario.py` | — | pass |
| Sim | Simulator core: geometry, faults, batching, dropouts, CLI parsing, sample routes | `test_simulator_core.py` | — | pass |

## Edge cases — tracking and GPS (T1–T14)

| ID | Required behaviour | Tests | Status |
|---|---|---|---|
| T1 | No trip started → bus hidden from students | `test_tracking.py::test_t1_no_trip_no_bus`, `test_live_state.py::test_trip_without_fix_not_listed_yet` | pass |
| T2 | Auto-close after 15 min without fixes, "auto-closed" in reports | `acceptance/test_edge_cases_sim.py::test_t2_driver_forgets_to_end_trip_auto_closed_after_15_min`, `test_jobs_tracking.py::test_t2_*` | pass |
| T3 | Accuracy >50 m discarded; last good position stays | `acceptance/test_tc06_bad_fixes.py`, `test_tracking.py::test_tc6_*` | pass |
| T4 | Implied speed >120 km/h rejected and logged; the next consistent fix is accepted | `acceptance/test_tc06_bad_fixes.py` (rejected_fixes rows, the fix after a spike accepted) | pass |
| T5 | "Last seen"; stale after 30 s, offline after 2 min | `acceptance/test_tc08_stale_offline.py` | pass / app (styling) |
| T6 | Offline buffering, ordered upload, history filled in, live jumps to the latest fix | `acceptance/test_tc09_offline_buffer.py`, `acceptance/test_simulator_core.py::test_dropout_buffers_then_uploads_in_order_in_chunks` | pass (server) / app (P8) / field (FT-D6) |
| T7 | Battery saver kills the app → warning on next open; admin sees offline; onboarding | server side: offline state is covered by T5 | app (P8) / ops (P9 onboarding doc) / field (FT-D7) |
| T8 | Location permission denied → Start blocked, with a settings shortcut | — | app (P8) |
| T9 | Approximate location only → ask for precise location before start | — | app (P8) |
| T10 | Second trip while one is active → server rejects; app offers resume or end | `acceptance/test_tc05_trip_twice.py`, `test_trips.py::test_tc5_*` | pass / app (dialog) |
| T11 | Two phones as the same driver → latest wins, older is told and stops uploading | `acceptance/test_tc03_session_replaced.py`, `test_auth.py::test_tc3_*`, `test_ws_live.py::test_revoked_session_socket_is_closed` | pass / app (signed-out screen) |
| T12 | Old or out-of-order fix → stored for history, not used for live | `acceptance/test_tc09_offline_buffer.py::test_tc9_backlog_arriving_out_of_order_is_history_only`, `test_tracking.py::test_t6_t12_*`, `::test_out_of_order_before_trip_start_rejected` | pass |
| T13 | Wrong phone clock → server receive time for freshness; skew flagged | `acceptance/test_edge_cases_sim.py::test_t13_phone_clock_running_ahead_like_time_scale`, `acceptance/test_tc08_stale_offline.py::test_tc8_freshness_uses_server_time_not_phone_time`, `test_tracking.py::test_t13_*` | pass |
| T14 | Parked with the engine running → "stopped", not offline | `acceptance/test_edge_cases_sim.py::test_t14_parked_with_engine_running_is_stopped_not_offline`, `test_tracking.py::test_t14_*` | pass / app (styling) |

## Edge cases — network and server (N1–N9)

| ID | Required behaviour | Tests | Status |
|---|---|---|---|
| N1 | Server asleep → "Connecting…", backoff, cached routes; keep-alive | `test_foundation.py::test_health_reports_db` (health endpoint used by keep-alive) | app (P7) / ops (P9 keep-alive) |
| N2 | WS drops → reconnect with backoff, "Reconnecting", refetch `/buses/live` | `acceptance/test_tc11_reconnect.py` | pass (server) / app (P7) |
| N3 | Student offline → cached routes and stops; "You are offline"; no stale bus shown as live | server side: stale/offline states (T5) | app (P7/P8) |
| N4 | Server restart → live state rebuilt from the next fix; the trip is not closed | `acceptance/test_tc19_restart.py`, `test_live_state.py::test_tc19_*`, `::test_n4_*` | pass |
| N5 | DB unavailable → live continues from memory; writes queued to a limit; 503 for reports | `test_tracking.py::test_n5_db_down_live_continues_and_writes_queue`, `::test_n5_writer_queue_is_bounded`, `::test_n5_revoked_session_refused_while_db_down`, `test_foundation.py::test_connection_lost_mid_request_is_503`; `acceptance/test_edge_cases_sim.py::test_n6_n5_history_complete_after_simulated_drive` (writer completeness) | pass / app (message) |
| N6 | Retry after a timeout → duplicates ignored via fix_id | `acceptance/test_tc07_duplicates.py` | pass |
| N7 | Rate limit → 429 with a wait time; the driver app keeps buffering | `acceptance/test_n7_rate_limit.py` (driver loop keeps a buffer through 429s, nothing lost), `test_foundation.py::test_general_ip_rate_limit_429_shape`, `::test_per_user_rate_limit` | pass / app (P8 backoff) |
| N8 | Maps quota or key rejected → map error state; list view still works; admin notified | — | app (P8) / ops (P9 budget alerts) |
| N9 | Push fails or token invalid → token deleted; one retry; alert shown in-app | `acceptance/test_tc15_permissions.py::test_tc15_n9_invalid_token_deleted_alert_still_shown_in_app`, `test_push.py::test_n9_*` | pass / app (in-app list) |

## Edge cases — nearby alerts and ETA (EC-A1–EC-A9)

| ID | Required behaviour | Tests | Status |
|---|---|---|---|
| EC-A1 | Student riding the bus → suppressed | `acceptance/test_tc14_away_and_rider.py` (two rider tests), `test_alerts.py::test_tc14_a1_*`, `::test_rider_flag_clears_once_beyond_radius` | pass |
| EC-A2 | Bus on a road ~400 m away, student indoors → alert sent (documented limitation) | `acceptance/test_tc13_alert_approach.py` (straight-line distance alerts) | pass / app (pause alert mode) |
| EC-A3 | Within 500 m but moving away → no alert | `acceptance/test_tc14_away_and_rider.py::test_tc14_bus_moving_away_inside_radius_no_alert`, `test_alerts.py::test_tc14_a3_*` | pass |
| EC-A4 | Two buses within a minute → one combined "2 buses are nearby" | `acceptance/test_edge_cases_sim.py::test_ec_a4_two_buses_within_a_minute_give_one_combined_alert`, `test_alerts.py::test_a4_*` | pass |
| EC-A5 | Student location older than 5 min → no alert; app asks for a refresh | `acceptance/test_tc15_permissions.py::test_tc15_a5_location_older_than_5_min_gets_no_alert`, `test_alerts.py::test_a5_*` | pass / app (message) |
| EC-A6 | Background location denied → alert mode can't be on; foreground-only offered | `acceptance/test_tc15_permissions.py::test_tc15_unusable_student_locations_are_refused_with_reasons` | pass (server) / app (P8) |
| EC-A7 | Notifications denied or muted → persistent warning in alert settings | `acceptance/test_tc15_permissions.py::test_tc15_alert_mode_needs_notifications_explicit_error`, `test_alerts_api.py::test_enabling_alerts_requires_a_push_token` | pass (server) / app (P8) |
| EC-A8 | Breakdown or trip ended → no approaching alerts; status text shown | `acceptance/test_edge_cases_sim.py::test_ec_a8_breakdown_status_stops_alerts_and_shows_status`, `test_alerts.py::test_a8_*` | pass / app (status text) |
| EC-A9 | Stationary bus → ETA capped at "30+ min" | `acceptance/test_tc12_eta.py::test_a9_parked_bus_eta_is_capped_at_30_min`, `test_eta.py::test_a9_stationary_bus_is_capped` | pass / app ("30+ min" label) |

## Edge cases — accounts, roles and admin data (U1–U8)

| ID | Required behaviour | Tests | Status |
|---|---|---|---|
| U1 | Non-university Google account → allowed | `acceptance/test_tc01_google_sign_in.py` | pass |
| U2 | Delete the account with alert mode on → alerts stop; location, push token and alert log deleted | `acceptance/test_tc20_delete_account.py`, `test_alerts.py::test_u2_*`, `test_me.py::test_tc20_*` | pass |
| U3 | Driver loses their phone or changes number → admin deactivates and re-adds; old sessions signed out | `test_admin_drivers.py::test_u3_deactivate_driver_revokes_sessions_and_frees_phone`, `::test_phone_change_revokes_sessions`, `test_auth.py::test_u3_*` | pass |
| U4 | OTP expires after 5 min; 3 resends per 10 min; contact an admin | `test_auth.py::test_u4_code_expires_after_ttl`, `::test_u4_resend_limit_per_phone` | pass / app (help text) |
| U5 | Removing the last admin is blocked | `acceptance/test_tc17_blocked_deletes.py::test_tc17_last_admin_cannot_be_removed`, `test_admin_admins.py::test_u5_*` | pass |
| U6 | Delete blocked during an active trip; edits apply from the next trip, with a warning; soft deletes | `acceptance/test_tc17_blocked_deletes.py::test_tc17_route_stop_and_bus_cannot_be_removed_during_a_trip`, `test_routes_admin.py::test_tc17_u6_*`; **`::test_tc17_u6_stop_added_mid_trip_does_not_change_running_trip_etas`** | pass; **xfail-bug P6-1** (edits leak into the running trip's ETAs) |
| U7 | Directions fails → draft with an error; cannot be activated without a polyline | `acceptance/test_tc16_polyline_failed.py`, `test_routes_admin.py::test_tc16_*` | pass |
| U8 | Substitute driver → admin relinks the bus; logged; trips show the actual driver | `test_admin_drivers.py::test_u8_substitute_relink_is_audited_and_trips_keep_actual_driver`, `acceptance/test_tc05_trip_twice.py::test_tc5_bus_in_use_by_another_driver_is_409` | pass |

## Field test (test plan p.3) and launch gate (p.4)

| ID | Item | Coverage | Status |
|---|---|---|---|
| FT-B1 | Driver app installed, signed in by phone, battery optimisation off | — | field (manual) |
| FT-B2 | Student phones signed in, alert mode on, location "always", notifications allowed | — | field (manual) |
| FT-B3 | Route and stops created; polyline correct on the map | server: `acceptance/test_e2e_scenario.py` | field (manual) |
| FT-B4 | Server awake; Maps keys restricted | — | ops (P9) / field |
| FT-D1 | Trip starts in two taps; bus visible to students within 5 s | server: `acceptance/test_tc10_live_latency.py` | field (manual) |
| FT-D2 | Marker follows the bus without jumping | server: T3/T4 filtering (`test_tc06_bad_fixes.py`) | field (manual) |
| FT-D3 | "Delayed" appears on student phones | server: `acceptance/test_e2e_scenario.py` (`bus_status` on WS, status on ETA) | field (manual) |
| FT-D4 | Student standing still gets one alert at ~500 m | server: `acceptance/test_tc13_alert_approach.py` | field (manual) |
| FT-D5 | Student on the bus gets no alert | server: `acceptance/test_tc14_away_and_rider.py` | field (manual) |
| FT-D6 | Airplane mode for 1 min → map catches up | server: `acceptance/test_tc09_offline_buffer.py` | field (manual) |
| FT-D7 | Phone locked for 10 min → uploads continue | — | app (P8 foreground service) / field |
| FT-D8 | ETA vs real arrival error noted | server formula: `acceptance/test_tc12_eta.py` | field (manual) |
| FT-A1 | Trip ends; report distance and times close to the real values | server: `acceptance/test_tc18_reports.py` | field (manual) |
| FT-A2 | Driver battery use recorded | — | field (manual) |
| FT-A3 | Dead spots, wrong alerts and slow updates logged with time and place | — | field (manual) |
| LG1 | TC1–TC20 pass on staging, no open high-severity bug | server: this suite (local); staging run plus app tests outstanding; P6-1 open (medium) | ops (P10) |
| LG2 | Field test completed on a real bus, no blocking issue | — | field (manual) |
| LG3 | Driver completes a full trip using only the written onboarding steps | — | ops (P9 docs) / field |
| LG4 | Admin creates a route, adds a stop, posts an announcement and exports a trip report, unaided | server: `acceptance/test_e2e_scenario.py` (route → CSV), `test_announcements.py` | app (P8) / field |
| LG5 | Maps quotas and budget alerts configured; keys restricted | — | ops (P9) |
| LG6 | Privacy notice and location consent screens approved | server: consents recorded (`test_me.py::test_consent_recorded_once`) | app (P7) / ops |
| LG7 | Runbook rollback plan rehearsed once | — | ops (P9/P10) |

## Open bugs found by Phase 6

| Bug | Severity | Case | Test | Summary |
|---|---|---|---|---|
| P6-1 | medium | U6 / TC17 | `acceptance/test_tc17_blocked_deletes.py::test_tc17_u6_stop_added_mid_trip_does_not_change_running_trip_etas` (strict xfail) | When an admin adds or moves a stop during a trip, `regenerate_polyline` rewrites every `stops.dist_along_m` for the new polyline straight away. The running trip keeps its frozen `RouteGeom`. `GET /stops/{id}/eta` subtracts the bus position on the old polyline from the stop distance on the new one, so ETAs jump. In the test, adding a first stop ~600 m before the start moved one ETA from 150 s to 222 s. Fix direction: snap stops onto the trip's frozen polyline for active trips, or freeze the stop distances per trip at start. `rebuild_live` after a restart also loads the *new* polyline for an active trip. |

## V1.1 extensions (ADR-9)

| ID | Test | Status |
|---|---|---|
| X1 | `test_direction.py`: default direction, unknown direction → 400, reversed-route ETA for `from_campus`, `to_campus` unchanged, schedule slot matches only its own direction, admin schedule direction | pass |


## V1.2 extensions (ADR-10), planned

| ID | Test | Status |
|---|---|---|
| X4 | password login by userid / email / phone; same `INVALID_CREDENTIALS` for unknown and wrong; lockout after `login_max_failures`; single driver session (`SESSION_REPLACED`); temporary password shown once and `must_change_password` cleared on change; reset revokes sessions; hash never in any response or log | done: `test_auth.py::test_password_hash_roundtrip_and_format`, `::test_driver_login_returns_tokens_bus_and_must_change`, `::test_login_by_userid_email_and_phone_with_normalisation`, `::test_tc2_failures_are_uniform`, `::test_login_validation_is_400`, `::test_driver_without_password_cannot_login`, `::test_lockout_after_n_failures_then_unlock_after_expiry`, `::test_success_resets_failure_counter`, `::test_login_per_ip_rate_limit`, `::test_tc3_second_login_replaces_first_session`, `::test_change_password_flow`, `::test_change_password_requires_driver_token`, `::test_change_password_revokes_other_live_sessions`, `::test_hash_never_in_any_response`; `test_admin_drivers.py::test_create_with_userid_email_profile_and_one_time_password`, `::test_create_requires_an_identifier_and_valid_formats`, `::test_duplicate_userid_email_phone_are_validation_errors`, `::test_patch_profile_identifiers_and_keep_one_identifier`, `::test_reset_password_returns_new_one_once_unlocks_and_signs_out`, `::test_reset_password_unknown_driver_and_non_admin`; `acceptance/test_tc02_uniform_login.py`; `test_foundation.py::test_removed_otp_endpoints_are_gone` |
| X5 | registration validation; one profile per student; approve and reject with note; unregistered student gets 403 `REGISTRATION_REQUIRED` from live buses, ETA, pickups and alert settings; cascade on account deletion | `tests/test_students.py`: `test_x5_registration_create_read_and_one_profile_per_student`, `test_x5_registration_validation`, `test_x5_phone_is_normalised_to_e164`, `test_x5_route_must_be_active`, `test_x5_resubmit_after_rejection_goes_back_to_pending_and_clears_the_note`, `test_x5_approved_student_cannot_change_route_or_bus_but_can_update_contact`, `test_x5_nearest_route`, `test_x5_role_checks`, `test_x7_unapproved_students_are_gated` (none, pending, rejected), `test_x7_approved_student_sees_only_their_routes_buses`, `test_x7_websocket_fan_out_is_scoped_to_the_students_route`, `test_x7_pins_need_approval_and_the_profile_route`, `test_x7_alerts_only_reach_approved_students_on_the_trips_route`, `test_x5_deleting_the_account_deletes_the_registration`; `tests/test_me.py::test_tc20_delete_student_removes_personal_data` (profile row). Passing (phase 4) |
| X6 | two concurrent approvals for the last seat give one 409 `NO_SEAT`; bus on another route refused; capacity null and 0 handled | `tests/test_students.py`: `test_x6_two_concurrent_approvals_for_the_last_seat` (real pool, committed rows, `asyncio.gather`: one 200, one 409), `test_x6_approve_assigns_bus_and_audits`, `test_x6_wrong_route_inactive_unknown_bus_and_unset_capacity_are_refused`, `test_x6_seat_limit_reassign_and_reject_frees_the_seat`, `test_x6_reject_needs_a_note_and_a_known_student`, `test_x6_bus_capacity_can_be_set_and_cleared`. Capacity null is 409 `NO_SEAT`. Passing (phase 4) |
| X7 | admin list filters and cursor; summary counts per status, route and bus; driver roster shows name and department only | `tests/test_students.py`: `test_x6_admin_list_filters_search_cursor_and_summary`, `test_x6_driver_roster_shows_name_and_department_only`. Passing (phase 4; the app screens are phase 5) |
| X8 | start push goes only to approved students of the trip's bus; zero recipients tolerated; push failure never breaks the start; `moved_at` set once after the speed threshold and kept across a restart | `tests/test_journey.py`: `test_x8_journey_push_goes_to_approved_students_of_that_bus_only`, `test_x8_journey_push_body_follows_direction`, `test_x8_journey_push_with_zero_recipients_is_a_noop`, `test_x8_push_failure_never_breaks_trip_start`, `test_x8_moved_at_is_set_once_and_only_after_speed_exceeds_threshold`, `test_x8_restart_rebuild_keeps_moved_at`. Passing (phase 6 server) |
| X9 | `to_campus` geofence end (`closed_by='arrival'`, `arrived_at`, `trip_ended`); `from_campus` last-stop end (lowest sequence); button end and `arrived_at` only inside the zone; one end when button and geofence race; no early end at the start point, before `moved_at` or before `arrival_min_trip_s`; geofence off while campus point unset; silence auto-close unaffected; reports and CSV columns; campus settings validation and `/config` | `tests/test_journey.py`: `test_x8_to_campus_arrival_ends_trip_with_closed_by_arrival`, `test_x8_no_early_end_at_the_start_point_min_time_and_moved_guard`, `test_x8_no_end_before_moved_even_after_min_time`, `test_x8_geofence_is_off_when_campus_is_unset`, `test_x8_from_campus_ends_at_the_travel_order_last_stop`, `test_x8_driver_button_still_works_and_records_arrived_at_only_inside_the_zone`, `test_x8_button_and_geofence_race_yields_exactly_one_end`, `test_x8_driver_button_first_then_late_fix_is_a_clean_404`, `test_x9_auto_close_is_unaffected_by_arrival_fields`, `test_x9_reports_and_csv_carry_direction_moved_and_arrived`, `test_x9_settings_read_write_and_validation`; `test_reports_admin.py::test_trip_report_csv_export` (columns). Passing (phase 6 server) |
