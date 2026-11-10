"""Photo upload helpers: raw JPEG/PNG request bodies stored as bytea (v13-spec decision 5).

The bytes are never logged, never put in audit meta and never returned by a list.
"""

from __future__ import annotations

from fastapi import Request

from app.errors import ValidationFailed

_JPEG = b"\xff\xd8\xff"
_PNG = b"\x89PNG\r\n\x1a\n"
CONTENT_TYPES = ("image/jpeg", "image/png")


def sniff_image(data: bytes) -> str | None:
    """The MIME type a byte string really is (by its magic bytes), or None."""
    if data.startswith(_JPEG):
        return "image/jpeg"
    if data.startswith(_PNG):
        return "image/png"
    return None


def check_image(data: bytes, content_type: str | None, max_bytes: int) -> str:
    """Validate an uploaded image; returns its MIME type. The declared type must match the bytes."""
    declared = (content_type or "").split(";")[0].strip().lower()
    if declared not in CONTENT_TYPES:
        raise ValidationFailed("Content-Type: send image/jpeg or image/png")
    if not data:
        raise ValidationFailed("body: the image is empty")
    if len(data) > max_bytes:
        raise ValidationFailed(f"body: the image is larger than {max_bytes // 1024} KB")
    actual = sniff_image(data)
    if actual is None or actual != declared:
        raise ValidationFailed("body: the bytes are not a valid JPEG or PNG image")
    return actual


async def read_image(request: Request) -> tuple[bytes, str]:
    """Read and validate the raw request body without buffering more than the limit."""
    max_bytes = int(request.app.state.settings_store.get_cached("student_photo_max_bytes"))
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > max_bytes:
        raise ValidationFailed(f"body: the image is larger than {max_bytes // 1024} KB")
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > max_bytes:
            raise ValidationFailed(f"body: the image is larger than {max_bytes // 1024} KB")
        chunks.append(chunk)
    data = b"".join(chunks)
    return data, check_image(data, request.headers.get("content-type"), max_bytes)
