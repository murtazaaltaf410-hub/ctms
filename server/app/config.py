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
OtpProviderName = Literal["console", "firebase"]


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
    otp_provider: OtpProviderName | None = None
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

    # --- Rate limits (ADR-3) ----------------------------------------------------
    rate_general_per_user: int = 120
    rate_general_per_user_window_s: int = 60
    rate_general_per_ip: int = 300
    rate_general_per_ip_window_s: int = 60
    rate_otp_request_per_ip: int = 20
    rate_otp_request_per_ip_window_s: int = 600
    rate_locations_per_user: int = 60
    rate_locations_per_user_window_s: int = 60

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
    otp_ttl_seconds: int = 300
    otp_max_sends_per_window: int = 3
    otp_window_seconds: int = 600
    otp_max_attempts: int = 5
    location_retention_days: int = 90
    student_location_ttl_s: int = 300
    otp_request_retention_s: int = 86400
    timezone: str = "Asia/Kolkata"

    @field_validator("google_oauth_client_ids", mode="before")
    @classmethod
    def _split_client_ids(cls, value: object) -> object:
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

    @property
    def resolved_otp_provider(self) -> OtpProviderName:
        return self.otp_provider or "console"

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
        if self.otp_provider is None:
            problems.append("OTP_PROVIDER must be set (firebase)")
        elif self.otp_provider == "console":
            problems.append("OTP_PROVIDER=console is for development only (ADR-7)")
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
