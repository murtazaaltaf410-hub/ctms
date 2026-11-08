"""CTMS GPS simulator: a fake driver that drives a route and uploads timed fix batches.

It signs in as a driver, starts (or resumes) a trip, then drives along the trip's
route polyline (`GET /routes/{id}`) or a local GPX/JSON file at a fixed speed. A
fix is recorded every `--fix-every` seconds and the buffered fixes are posted to
`POST /trips/{id}/locations` every `--interval` seconds, each with a client
`fix_id` and the phone's `recorded_at`, like the driver app does (T6, N6).

    cd server
    # Dev server with the console OTP provider (the code is printed in the server log):
    uv run python scripts/simulate.py --phone +910000000001 --minutes 2
    # Non-interactive, 10x faster, a 60 s offline period and some bad fixes:
    uv run python scripts/simulate.py --phone +910000000001 --otp 123456 --time-scale 10 \\
        --dropout 30:60 --bad-accuracy-every 7 --spike-every 11 --duplicate-every 5 \\
        --status delayed@00:45 --status "on_time@01:30"
    # Existing access token, a local route file, leave the trip running:
    uv run python scripts/simulate.py --token "$TOKEN" --route-file scripts/routes/campus_loop.gpx --no-end

Faults (every N-th recorded fix; the first fix is never corrupted):
  --bad-accuracy-every N   accuracy 80 m          -> server rejects ACCURACY_TOO_LOW (T3)
  --spike-every N          a ~2 km jump           -> SPEED_IMPLAUSIBLE (T4)
  --duplicate-every N      the fix is sent twice  -> DUPLICATE (N6)
  --dropout START:SECONDS  no network from START s for SECONDS s; fixes are buffered
                           and uploaded in order when back online (T6)

`--time-scale K` runs simulated time K times faster than the wall clock. The
phone timestamps (`recorded_at`) follow simulated time, so speeds stay plausible
but run ahead of the server clock (the server flags the skew, T13). Keep
`--interval / --time-scale` at 1 s or more to stay under the location rate limit.

The importable core (`Route`, `DriveConfig`, `drive`, `batches`, `timeline`)
is pure: no I/O, no clock. The acceptance tests use it to generate fix streams.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import random
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

EARTH_RADIUS_M = 6_371_008.8   # same as app.geo
LatLng = tuple[float, float]

# --------------------------------------------------------------------------- geometry


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def bearing_deg(a: LatLng, b: LatLng) -> float:
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


def offset(lat: float, lng: float, *, north_m: float = 0.0, east_m: float = 0.0) -> LatLng:
    """The point `north_m`/`east_m` metres from (lat, lng) (flat-earth; fine for a few km)."""
    dlat = math.degrees(north_m / EARTH_RADIUS_M)
    dlng = math.degrees(east_m / (EARTH_RADIUS_M * math.cos(math.radians(lat))))
    return lat + dlat, lng + dlng


def decode_polyline(encoded: str) -> list[LatLng]:
    """Google Encoded Polyline (precision 1e5), as served by `GET /routes/{id}`."""
    points: list[LatLng] = []
    index, lat, lng, n = 0, 0, 0, len(encoded)
    while index < n:
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                if index >= n:
                    raise ValueError("truncated polyline")
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lng += deltas[1]
        points.append((lat / 1e5, lng / 1e5))
    return points


class Route:
    """A polyline with cumulative distances; `at(along_m)` interpolates a position."""

    def __init__(self, points: Sequence[LatLng]) -> None:
        pts = [(float(a), float(b)) for a, b in points]
        # Drop consecutive duplicates so every segment has a length and a heading.
        self.points: list[LatLng] = [p for i, p in enumerate(pts) if i == 0 or p != pts[i - 1]]
        if len(self.points) < 2:
            raise ValueError("a route needs at least two distinct points")
        self.cum = [0.0]
        for a, b in itertools.pairwise(self.points):
            self.cum.append(self.cum[-1] + haversine_m(a[0], a[1], b[0], b[1]))

    @property
    def length_m(self) -> float:
        return self.cum[-1]

    def at(self, along_m: float) -> tuple[float, float, float]:
        """(lat, lng, heading) `along_m` metres from the start, clamped to the route."""
        along = min(max(along_m, 0.0), self.length_m)
        i = 1
        while i < len(self.cum) - 1 and self.cum[i] < along:
            i += 1
        a, b = self.points[i - 1], self.points[i]
        seg = self.cum[i] - self.cum[i - 1]
        f = (along - self.cum[i - 1]) / seg if seg > 0 else 0.0
        return a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]), round(bearing_deg(a, b), 1)


# --------------------------------------------------------------------------- fix stream

KIND_EXPECTED = {"good": None, "bad_accuracy": "ACCURACY_TOO_LOW", "spike": "SPEED_IMPLAUSIBLE",
                 "duplicate": "DUPLICATE"}


@dataclass(frozen=True)
class SimFix:
    seq: int                 # 1-based index of the recorded fix (a duplicate repeats its original's seq)
    t: float                 # simulated seconds since the drive started
    fix_id: UUID
    lat: float
    lng: float
    accuracy: float
    speed: float             # m/s
    heading: float
    recorded_at: datetime
    along_m: float           # true distance driven along the route at this instant
    kind: str = "good"       # good | bad_accuracy | spike | duplicate

    @property
    def expected(self) -> str | None:
        """The rejection reason the server should give, or None when it should accept the fix."""
        return KIND_EXPECTED[self.kind]

    def payload(self) -> dict[str, Any]:
        """The JSON object for one entry of `{"fixes": [...]}` (API spec p.3)."""
        return {"fix_id": str(self.fix_id), "lat": round(self.lat, 7), "lng": round(self.lng, 7),
                "accuracy": self.accuracy, "speed": round(self.speed, 2), "heading": self.heading,
                "recorded_at": self.recorded_at.astimezone(UTC).isoformat().replace("+00:00", "Z")}


@dataclass(frozen=True)
class DriveConfig:
    speed_kmh: float = 25.0
    fix_every_s: float = 3.0
    minutes: float | None = None        # None: until the end of the route; longer: park at the end (T14)
    accuracy_m: float = 8.0
    jitter_m: float = 0.0               # random position noise (0 = exact, reproducible distances)
    bad_accuracy_every: int = 0
    bad_accuracy_m: float = 80.0
    spike_every: int = 0
    spike_m: float = 2000.0
    duplicate_every: int = 0
    seed: int | None = None


def drive(route: Route, cfg: DriveConfig, start: datetime) -> Iterator[SimFix]:
    """Timed fixes along `route` at `cfg.speed_kmh`, starting at phone time `start`.

    One fix every `fix_every_s` from t=0, plus a final fix at the exact end time.
    Every N-th fix is corrupted as configured (never the first, which has no
    previous position to be judged against)."""
    if cfg.speed_kmh <= 0 or cfg.fix_every_s <= 0:
        raise ValueError("speed_kmh and fix_every_s must be positive")
    rng = random.Random(cfg.seed)  # noqa: S311  (simulated GPS noise, not security)
    v = cfg.speed_kmh / 3.6
    duration = cfg.minutes * 60 if cfg.minutes is not None else route.length_m / v
    times = [i * cfg.fix_every_s for i in range(int(duration // cfg.fix_every_s) + 1)]
    if duration - times[-1] > 1e-6:
        times.append(duration)
    for seq, t in enumerate(times, start=1):
        along = min(v * t, route.length_m)
        lat, lng, heading = route.at(along)
        if cfg.jitter_m:
            lat, lng = offset(lat, lng, north_m=rng.gauss(0, cfg.jitter_m), east_m=rng.gauss(0, cfg.jitter_m))
        kind, accuracy = "good", cfg.accuracy_m
        if seq > 1 and cfg.spike_every and seq % cfg.spike_every == 0:
            kind = "spike"
            lat, lng = offset(lat, lng, north_m=cfg.spike_m)
        elif seq > 1 and cfg.bad_accuracy_every and seq % cfg.bad_accuracy_every == 0:
            kind, accuracy = "bad_accuracy", cfg.bad_accuracy_m
        fix = SimFix(seq=seq, t=t, fix_id=uuid4(), lat=lat, lng=lng, accuracy=accuracy,
                     speed=v if along < route.length_m else 0.0, heading=heading,
                     recorded_at=start + timedelta(seconds=t), along_m=along, kind=kind)
        yield fix
        if kind == "good" and cfg.duplicate_every and seq % cfg.duplicate_every == 0:
            yield replace(fix, kind="duplicate")


@dataclass(frozen=True)
class Dropout:
    start_s: float
    seconds: float

    def covers(self, t: float) -> bool:
        return self.start_s <= t < self.start_s + self.seconds


@dataclass(frozen=True)
class Batch:
    send_t: float                    # simulated seconds since the start when this request is made
    fixes: tuple[SimFix, ...]
    backlog: bool = False            # True when it drains fixes buffered while offline

    @property
    def payload(self) -> dict[str, Any]:
        return {"fixes": [f.payload() for f in self.fixes]}


def batches(fixes: Iterable[SimFix], *, interval_s: float, dropouts: Sequence[Dropout] = (),
            batch_max: int = 20) -> Iterator[Batch]:
    """Upload ticks every `interval_s` from t=0. Each tick sends every fix recorded so
    far, in recorded order, in chunks of `batch_max`; a tick inside a dropout sends
    nothing and the fixes stay buffered (T6)."""
    if interval_s <= 0 or batch_max < 1:
        raise ValueError("interval_s must be positive and batch_max at least 1")
    pending = list(fixes)
    i, k, buffer = 0, 0, []
    while i < len(pending) or buffer:
        tick = k * interval_s
        k += 1
        while i < len(pending) and pending[i].t <= tick + 1e-9:
            buffer.append(pending[i])
            i += 1
        if not buffer or any(d.covers(tick) for d in dropouts):
            continue
        backlog = buffer[0].t < tick - interval_s - 1e-9
        for j in range(0, len(buffer), batch_max):
            yield Batch(send_t=tick, fixes=tuple(buffer[j:j + batch_max]), backlog=backlog)
        buffer = []


@dataclass(frozen=True)
class StatusChange:
    at_t: float
    status: str                      # on_time | delayed | breakdown
    note: str | None = None


@dataclass(frozen=True, order=True)
class Event:
    t: float
    order: int
    item: Batch | StatusChange = field(compare=False)


def timeline(batch_list: Iterable[Batch], statuses: Iterable[StatusChange] = ()) -> list[Event]:
    """Batches and status changes in time order (a status change at the same instant goes first)."""
    events = [Event(s.at_t, 0, s) for s in statuses]
    events += [Event(b.send_t, 1 + n, b) for n, b in enumerate(batch_list)]
    return sorted(events)


def driven_distance_m(fixes: Iterable[SimFix]) -> float:
    """Distance between consecutive good fixes: what the server should report (TC18)."""
    good = [f for f in fixes if f.kind == "good"]
    return sum(haversine_m(a.lat, a.lng, b.lat, b.lng) for a, b in itertools.pairwise(good))


# --------------------------------------------------------------------------- inputs


def parse_mmss(value: str) -> float:
    """'MM:SS', 'H:MM:SS' or plain seconds -> seconds."""
    parts = [float(p) for p in value.strip().split(":")]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total


def parse_dropout(value: str) -> Dropout:
    start, _, seconds = value.partition(":")
    if not seconds:
        raise argparse.ArgumentTypeError("expected START:SECONDS, e.g. 60:180")
    return Dropout(float(start), float(seconds))


def parse_status(value: str) -> StatusChange:
    """'delayed@MM:SS' or 'delayed@MM:SS@note text'."""
    status, _, rest = value.partition("@")
    at, _, note = rest.partition("@")
    if status not in ("on_time", "delayed", "breakdown") or not at:
        raise argparse.ArgumentTypeError("expected on_time|delayed|breakdown@MM:SS[@note]")
    return StatusChange(parse_mmss(at), status, note or None)


def load_route_file(path: Path) -> list[LatLng]:
    """GPX (trkpt/rtept/wpt) or JSON: [[lat, lng], ...], {"points": [...]}, {"polyline": "..."}
    or {"stops": [{"lat": .., "lng": ..}, ...]}."""
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".gpx":
        root = ET.fromstring(text)  # noqa: S314  (a local file chosen by the operator)
        points: list[LatLng] = []
        for tag in ("trkpt", "rtept", "wpt"):
            points = [(float(e.attrib["lat"]), float(e.attrib["lon"])) for e in root.iter()
                      if e.tag.rsplit("}", 1)[-1] == tag]
            if points:
                return points
        raise ValueError(f"{path}: no trkpt/rtept/wpt points")
    data = json.loads(text)
    if isinstance(data, dict):
        if "polyline" in data:
            return decode_polyline(data["polyline"])
        data = data.get("points") or data.get("stops") or []
    return [(float(p["lat"]), float(p["lng"])) if isinstance(p, dict) else (float(p[0]), float(p[1]))
            for p in data]


# --------------------------------------------------------------------------- HTTP runner


class SimError(RuntimeError):
    pass


def mmss(seconds: float) -> str:
    return f"{int(seconds // 60):02d}:{int(seconds % 60):02d}"


class Api:
    """Thin httpx wrapper: bearer auth, one silent refresh on TOKEN_EXPIRED, error envelope."""

    def __init__(self, base_url: str, timeout_s: float = 10.0) -> None:
        import httpx

        self._httpx = httpx
        self.client = httpx.Client(base_url=base_url.rstrip("/") + "/api/v1", timeout=timeout_s)
        self.access: str | None = None
        self.refresh: str | None = None

    def call(self, method: str, path: str, body: Any = None, *, auth: bool = True) -> Any:
        resp = self._send(method, path, body, auth)
        if resp.status_code == 401 and self.refresh and self._code(resp) == "TOKEN_EXPIRED":
            tokens = self._send("POST", "/auth/refresh", {"refresh_token": self.refresh}, False)
            if tokens.status_code == 200:
                self.access, self.refresh = tokens.json()["access_token"], tokens.json()["refresh_token"]
                resp = self._send(method, path, body, auth)
        return resp

    def _send(self, method: str, path: str, body: Any, auth: bool) -> Any:
        headers = {"Authorization": f"Bearer {self.access}"} if auth and self.access else {}
        return self.client.request(method, path, json=body, headers=headers)

    @staticmethod
    def _code(resp: Any) -> str | None:
        try:
            return resp.json()["error"]["code"]
        except (ValueError, KeyError, TypeError):
            return None

    def expect(self, resp: Any, *codes: int) -> Any:
        if resp.status_code not in codes:
            raise SimError(f"{resp.request.method} {resp.request.url.path} -> {resp.status_code} "
                           f"{self._code(resp) or resp.text[:200]}")
        return resp.json() if resp.content else None


def sign_in(api: Api, args: argparse.Namespace) -> None:
    if args.token:
        api.access = args.token
        return
    if not args.phone:
        raise SimError("give --token, or --phone (dev console OTP)")
    api.expect(api.call("POST", "/auth/phone/request", {"phone": args.phone}, auth=False), 202)
    otp = args.otp or input(f"OTP for {args.phone} (see the server log): ").strip()
    tokens = api.expect(api.call("POST", "/auth/phone/verify", {"phone": args.phone, "otp": otp}, auth=False), 200)
    api.access, api.refresh = tokens["access_token"], tokens["refresh_token"]
    print(f"signed in as {tokens['user']['name']} ({tokens['user']['role']})")


def start_or_resume(api: Api, route_id: str | None) -> dict:
    resp = api.call("POST", "/trips/start", {"route_id": route_id} if route_id else {})
    if resp.status_code == 409:   # T10: resume the existing trip, like the app offers
        trip = api.expect(api.call("GET", "/trips/active"), 200)
        if trip is None:
            raise SimError("409 TRIP_ALREADY_ACTIVE but no active trip for this driver (the bus is in use)")
        print(f"resuming active trip {trip['id']} on {trip['bus_label']} / {trip['route_name']}")
        return trip
    trip = api.expect(resp, 201)
    print(f"started {trip['type']} trip {trip['id']} on {trip['bus_label']} / {trip['route_name']}")
    return trip


def route_points(api: Api, args: argparse.Namespace, trip: dict) -> list[LatLng]:
    if args.route_file:
        return load_route_file(Path(args.route_file))
    route = api.expect(api.call("GET", f"/routes/{trip['route_id']}"), 200)
    if not route.get("polyline"):
        raise SimError(f"route {route['name']} has no polyline; pass --route-file")
    return decode_polyline(route["polyline"])


def run(args: argparse.Namespace) -> int:
    api = Api(args.base_url)
    sign_in(api, args)
    trip = start_or_resume(api, args.route_id)
    route = Route(route_points(api, args, trip))
    cfg = DriveConfig(speed_kmh=args.speed_kmh, fix_every_s=args.fix_every, minutes=args.minutes,
                      jitter_m=args.jitter_m, bad_accuracy_every=args.bad_accuracy_every,
                      spike_every=args.spike_every, duplicate_every=args.duplicate_every, seed=args.seed)
    start = datetime.now(UTC)
    fixes = list(drive(route, cfg, start))
    events = timeline(batches(fixes, interval_s=args.interval, dropouts=args.dropout, batch_max=args.batch_max),
                      args.status)
    print(f"route {route.length_m:.0f} m, {len(fixes)} fixes, {sum(isinstance(e.item, Batch) for e in events)} "
          f"uploads, time scale x{args.time_scale:g}")
    totals: Counter[str] = Counter()
    carry: list[SimFix] = []        # fixes a failed request must resend
    wall0 = time.monotonic()
    n = 0
    for ev in events:
        delay = wall0 + ev.t / args.time_scale - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        if isinstance(ev.item, StatusChange):
            s = ev.item
            api.expect(api.call("POST", f"/trips/{trip['id']}/status", {"status": s.status, "note": s.note}), 204)
            print(f"[{mmss(ev.t)}] status -> {s.status}{f' ({s.note})' if s.note else ''}")
            continue
        n += 1
        carry = post_batch(api, trip["id"], [*carry, *ev.item.fixes], ev, n, totals, args.batch_max)
    if carry:
        carry = post_batch(api, trip["id"], carry, events[-1], n + 1, totals, args.batch_max)
    rejected = {k: v for k, v in totals.items() if k != "accepted"}
    reasons = f" {rejected}" if rejected else ""
    print(f"totals: accepted {totals['accepted']}, rejected {sum(rejected.values())}{reasons}, "
          f"unsent {len(carry)}; simulated distance {driven_distance_m(fixes):.0f} m")
    if args.end:
        summary = api.expect(api.call("POST", f"/trips/{trip['id']}/end"), 200)
        print(f"trip ended: distance {summary['distance_m']:.0f} m, duration {summary['duration_s']:.0f} s, "
              f"avg {summary['avg_speed_mps'] * 3.6:.1f} km/h")
    else:
        print(f"trip {trip['id']} left running (--no-end)")
    return 0


def post_batch(api: Api, trip_id: str, fixes: list[SimFix], ev: Event, n: int, totals: Counter[str],
               batch_max: int) -> list[SimFix]:
    """Post `fixes` in chunks; returns the fixes still to send (network error, 429, 5xx)."""
    for j in range(0, len(fixes), batch_max):
        chunk = fixes[j:j + batch_max]
        try:
            resp = api.call("POST", f"/trips/{trip_id}/locations", {"fixes": [f.payload() for f in chunk]})
        except api._httpx.TransportError as exc:
            print(f"[{mmss(ev.t)}] upload {n}: network error ({exc.__class__.__name__}); keeping {len(fixes) - j} "
                  f"fixes buffered")
            return fixes[j:]
        if resp.status_code == 429 or resp.status_code >= 500:
            print(f"[{mmss(ev.t)}] upload {n}: {resp.status_code} {api._code(resp)} "
                  f"(Retry-After {resp.headers.get('Retry-After', '-')}); keeping {len(fixes) - j} fixes buffered")
            return fixes[j:]
        if resp.status_code == 401 and api._code(resp) == "SESSION_REPLACED":
            raise SimError("signed out: this driver signed in on another device (SESSION_REPLACED)")
        body = api.expect(resp, 200)
        reasons = Counter(r["reason"] for r in body["rejected"])
        totals["accepted"] += len(body["accepted"])
        totals.update(reasons)
        tag = " backlog" if isinstance(ev.item, Batch) and ev.item.backlog else ""
        print(f"[{mmss(ev.t)}] upload {n}{tag}: sent {len(chunk)}, accepted {len(body['accepted'])}, "
              f"rejected {len(body['rejected'])}{f' {dict(reasons)}' if reasons else ''}")
    return []


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="CTMS fake driver: drive a route and upload GPS fixes.",
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--base-url", default="http://localhost:8000", help="server origin (default %(default)s)")
    auth = p.add_argument_group("sign-in (one of)")
    auth.add_argument("--token", help="driver access token")
    auth.add_argument("--phone", help="driver phone; uses the OTP flow (dev console code)")
    auth.add_argument("--otp", help="OTP code (prompted if omitted)")
    p.add_argument("--route-id", help="route for the new trip (default: the bus's default route)")
    p.add_argument("--route-file", help="drive a local GPX/JSON route instead of the trip's polyline")
    p.add_argument("--speed-kmh", type=float, default=25.0, help="driving speed (default %(default)s)")
    p.add_argument("--fix-every", type=float, default=3.0, help="seconds between GPS fixes (default %(default)s)")
    p.add_argument("--interval", type=float, default=5.0, help="seconds between uploads (default %(default)s)")
    p.add_argument("--batch-max", type=int, default=20, help="fixes per request (default %(default)s)")
    p.add_argument("--minutes", type=float, help="simulated minutes to drive (default: to the end of the route; "
                                                 "longer parks at the last point)")
    p.add_argument("--dropout", type=parse_dropout, action="append", default=[], metavar="START:SECONDS",
                   help="offline from START s for SECONDS s; repeatable")
    p.add_argument("--bad-accuracy-every", type=int, default=0, metavar="N")
    p.add_argument("--spike-every", type=int, default=0, metavar="N")
    p.add_argument("--duplicate-every", type=int, default=0, metavar="N")
    p.add_argument("--jitter-m", type=float, default=0.0, help="random GPS noise in metres (default 0)")
    p.add_argument("--seed", type=int, help="random seed for --jitter-m")
    p.add_argument("--status", type=parse_status, action="append", default=[], metavar="STATUS@MM:SS[@NOTE]",
                   help="set the trip status at a simulated time, e.g. delayed@01:30; repeatable")
    p.add_argument("--end", action=argparse.BooleanOptionalAction, default=True,
                   help="end the trip when the drive finishes (default: --end)")
    p.add_argument("--time-scale", type=float, default=1.0, help="simulated seconds per wall second (default 1)")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.time_scale <= 0:
        raise SystemExit("--time-scale must be positive")
    try:
        return run(args)
    except SimError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted; the trip is still active (it auto-closes after 15 min without fixes)", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
