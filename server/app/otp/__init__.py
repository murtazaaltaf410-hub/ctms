"""Pluggable driver OTP providers (ADR-7). Selected by OTP_PROVIDER (console in dev)."""

from __future__ import annotations

from fastapi import Request

from app.config import Settings
from app.otp.base import OtpProvider
from app.otp.console import ConsoleOtpProvider
from app.otp.firebase import FirebaseOtpProvider, firebase_token_verifier


def build_otp_provider(config: Settings) -> OtpProvider:
    if config.resolved_otp_provider == "firebase":
        return FirebaseOtpProvider(firebase_token_verifier(config))
    return ConsoleOtpProvider(config.jwt_secret)


def get_otp_provider(request: Request) -> OtpProvider:
    return request.app.state.otp_provider


__all__ = ["ConsoleOtpProvider", "FirebaseOtpProvider", "OtpProvider", "build_otp_provider", "get_otp_provider"]
