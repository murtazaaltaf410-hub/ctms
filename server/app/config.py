"""Environment configuration (pydantic-settings).

Every threshold from the plan lives here as a field named exactly like its key in
the `settings` table (supabase/migrations/0003_seed.sql). The DB value wins when
present; these fields are the fallback (see app/settings_store.py). Outside
`dev`/`test` the app refuses to start with missing secrets (fail fast).
"""

from __future__ import annotations

import json
from functools import lru_cache
from typing import Literal

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEV_JWT_SECRET = "dev-only-insecure-jwt-secret-change-me-0000000000"
DEV_DATABASE_URL = "postgresql://postgres:postgres@localhost:55432/ctms"

AppEnv = Literal["dev", "test", "staging", "production"]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore", enable_decoding=False
    )

    # --- Runbook environment variables -------------------------------------
    app_env: AppEnv = "dev"
    database_url: str = DEV_DATABASE_URL
    jwt_secret: str = DEV_JWT_SECRET
    google_oauth_client_ids: list[str] = []
    fcm_credentials: str | None = None
    google_directions_key: str | None = None
    seed_admin_email: str | None = None

    # --- Server wiring --------------------------------------------------------
    # ADR-7: console (dev) or firebase. None = console in dev/test; required elsewhere.
    trust_proxy: bool = False
    db_pool_min_size: int = 1
    db_pool_max_size: int = 5
    # 0 only for a transaction pooler (Supabase port 6543); None = asyncpg default.
    db_statement_cache_size: int | None = None
    db_command_timeout_s: float = 10
    access_token_ttl_s: int = 900
    refresh_token_ttl_days: int = 30
    settings_cache_ttl_s: float = 30
    log_level: str = "INFO"
    cors_origins: list[str] = ["http://localhost:5173"]

    # --- Rate limits (ADR-3) ----------------------------------------------------
    rate_general_per_user: int = 120
    rate_general_per_user_window_s: int = 60
    rate_general_per_ip: int = 300
    rate_general_per_ip_window_s: int = 60
    rate_login_per_ip: int = 20
    rate_login_per_ip_window_s: int = 600
    rate_locations_per_user: int = 60
    rate_locations_per_user_window_s: int = 60

    # --- Phase 5: admin API, Routes API (ADR-8), reports -------------------------
    # Google Routes API computeRoutes; the key is GOOGLE_DIRECTIONS_KEY (runbook name).
    routes_api_url: str = "https://routes.googleapis.com/directions/v2:computeRoutes"
    routes_api_timeout_s: float = 10
    routes_api_max_intermediates: int = 25  # Routes API limit -> at most 27 stops per route
    admin_list_limit_default: int = 50      # API spec: ?limit default 50, max 200
    admin_list_limit_max: int = 200
    report_csv_max_rows: int = 10000
    alert_radius_min_m: float = 50          # PUT /admin/settings bounds for alert_radius_m
    alert_radius_max_m: float = 5000

    # --- Thresholds: same keys as the `settings` table ------------------------
    gps_accuracy_max_m: float = 50
    max_speed_kmh: float = 120
    location_batch_max: int = 20
    clock_skew_flag_s: float = 30
    stopped_speed_mps: float = 0.5
    stale_after_s: float = 30
    offline_after_s: float = 120
    trip_auto_close_s: float = 900
    db_batch_interval_s: float = 10
    history_downsample_s: float = 0
    ws_heartbeat_s: float = 25
    ws_auth_timeout_s: float = 5
    eta_ema_window_s: float = 60
    eta_v_min_kmh: float = 10
    eta_display_cap_s: float = 1800
    alert_radius_m: float = 500
    alert_bus_fix_max_age_s: float = 30
    student_fix_max_age_s: float = 300
    student_fix_max_accuracy_m: float = 100
    student_move_report_m: float = 100
    alert_rider_suppress_m: float = 50
    alert_combine_window_s: float = 60
    location_retention_days: int = 90
    student_location_ttl_s: int = 300
    timezone: str = "Asia/Kolkata"

    # --- Journey, arrival and password login (ADR-10, migration 0009) ---
    campus_lat: float | None = None          # None = campus point not set; geofence disabled
    campus_lng: float | None = None
    campus_radius_m: float = 150             # to_campus trip ends inside this radius of the campus
    last_stop_radius_m: float = 150          # from_campus trip ends inside this radius of the last stop
    moved_speed_mps: float = 1.5             # speed above which the bus counts as having moved
    arrival_min_trip_s: float = 120          # no arrival close sooner than this after the trip started
    login_max_failures: int = 5              # consecutive wrong passwords before the account locks
    login_lock_s: int = 900

    # --- Phase 3: trips, tracking, live state, ETA (not in the settings seed) ---
    # A trip is "scheduled" if it starts within this many seconds of a timetable slot.
    schedule_match_window_s: float = 900
    # OUT_OF_ORDER: fix recorded more than this long before the trip started.
    fix_before_start_grace_s: float = 120
    # A stop counts as "passed" once the bus is this far beyond it along the route.
    eta_passed_tolerance_m: float = 25
    # Forward snapping prefers an earlier segment within this distance of the best.
    snap_tie_tolerance_m: float = 25
    # N5: max queued DB writes (locations + rejections) while the DB is down.
    live_writer_queue_max: int = 50_000
    # Per-bus memory of recent fix_ids for DUPLICATE detection without the DB.
    live_seen_fix_ids_max: int = 5_000
    trip_auto_close_check_s: float = 60
    retention_interval_s: float = 60
    # WS: close a client silent for this long (about three missed heartbeats).
    ws_idle_timeout_s: float = 80

    # --- Phase 4: alerts + push (wiring; alert thresholds are the table keys above) ---
    # fcm | fake | log. None = log in dev/test, fcm elsewhere (fake/log refused outside dev).
    push_provider: Literal["fcm", "fake", "log"] | None = None
    push_queue_max: int = 1000           # pending push jobs; extra jobs are dropped and logged
    alert_queue_max: int = 1000          # pending fixes for the alert engine; oldest dropped when full
    alert_track_radius_factor: float = 2.0  # distances are tracked out to factor x alert_radius_m
    alert_rider_min_updates: int = 2     # A1: consecutive fixes within alert_rider_suppress_m = riding

    # --- V1.1 (ADR-9): student pickup pins and driver alerts -----------------------
    pickup_request_ttl_s: float = 3600       # a waiting pin expires after this long
    pickup_max_route_distance_m: float = 300  # a pin must be this close to the route line
    pickup_pass_m: float = 60                # the bus within this distance of a pin = picked up
    driver_alert_radius_m: float = 500       # alert the driver/student when the bus is this near a pin
    pickup_retention_s: int = 86400          # finished requests are deleted after this long
    pickup_label_max_chars: int = 60
    nearest_route_max_m: float = 2000        # GET /routes/nearest: farther than this from every route = null

    # --- V1.3 identity: photos and the digital bus card (migration 0011) -----------
    student_photo_max_bytes: int = 307200    # PUT /me/registration/photo and the admin driver photo
    bus_card_valid_until: str | None = None  # ISO date; None = the next 31 July (settings key of the same name)
    rate_bus_verify_per_ip: int = 30         # public GET /bus-card/verify
    rate_bus_verify_per_ip_window_s: int = 60

    # --- V1.3 stop alerts (migration 0012) ---------------------------------------
    stopped_alert_after_s: float = 300       # bus stationary this long: auto "Stopped" status + driver prompt
    stop_alert_check_s: float = 30           # how often the stop-alert job runs

    # --- Phase 9: GET /api/v1/config (runbook: minimum supported app version) ------
    # Also overridable per environment with a `min_app_version` row in the settings table.
    min_app_version: str = "1.0.0"
    app_update_url: str | None = None    # where an outdated build is sent (store / APK link)

    @property
    def resolved_push_provider(self) -> str:
        return self.push_provider or ("log" if self.is_dev else "fcm")

    @model_validator(mode="after")
    def _push_fail_fast(self) -> Settings:
        if not self.is_dev and self.resolved_push_provider != "fcm":
            raise ValueError(f"PUSH_PROVIDER={self.push_provider} is for development only; use fcm")
        return self

    @field_validator("google_oauth_client_ids", mode="before")
    @classmethod
    def _split_client_ids(cls, value: object) -> object:
        if isinstance(value, str):
            return [part.strip() for part in value.split(",") if part.strip()]
        return value

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _split_cors_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [part.strip() for part in value.split(",") if part.strip()]
        return value

    @field_validator("seed_admin_email", mode="before")
    @classmethod
    def _lower_email(cls, value: object) -> object:
        if isinstance(value, str):
            value = value.strip().lower()
            return value or None
        return value

    @property
    def is_dev(self) -> bool:
        return self.app_env in ("dev", "test")

    @model_validator(mode="after")
    def _fail_fast(self) -> Settings:
        if self.is_dev:
            return self
        problems: list[str] = []
        if self.jwt_secret == DEV_JWT_SECRET or len(self.jwt_secret) < 32:
            problems.append("JWT_SECRET must be a random value of at least 32 characters")
        if self.database_url == DEV_DATABASE_URL:
            problems.append("DATABASE_URL must be set")
        if not self.google_oauth_client_ids:
            problems.append("GOOGLE_OAUTH_CLIENT_IDS must list at least one client ID")
        if not self.fcm_credentials:
            problems.append("FCM_CREDENTIALS must be set")
        if not self.google_directions_key:
            problems.append("GOOGLE_DIRECTIONS_KEY must be set")
        if problems:
            raise ValueError(f"Invalid configuration for APP_ENV={self.app_env}: " + "; ".join(problems))
        return self

    def fcm_credentials_info(self) -> dict | str | None:
        """FCM_CREDENTIALS as a dict (inline JSON) or a file path."""
        if not self.fcm_credentials:
            return None
        raw = self.fcm_credentials.strip()
        return json.loads(raw) if raw.startswith("{") else raw


@lru_cache
def get_config() -> Settings:
    return Settings()
