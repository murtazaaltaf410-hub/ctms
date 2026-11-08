"""Route + stop persistence and polyline generation (PRD A2, edge cases U6, U7).

When a route's active stops change, `regenerate_polyline` calls the Routes API once and stores
the encoded polyline, `cum_dist_m` (cumulative metres per decoded point), `length_m` and each
stop's `dist_along_m`. On failure the route becomes a draft with `polyline_error` (POLYLINE_FAILED)
and its polyline columns are cleared (they no longer match the stops).
"""

from __future__ import annotations

from uuid import UUID

import asyncpg

from app.audit import write_audit
from app.integrations.routes_api import RouteProvider, RoutesApiError
from app.modules.routes.geo import cumulative_distances, decode_polyline, project_stops


async def active_stops(con: asyncpg.Connection, route_id: UUID) -> list[asyncpg.Record]:
    return await con.fetch(
        """select id, name, lat, lng, sequence, dist_along_m from public.stops
           where route_id = $1 and active order by sequence, created_at""",
        route_id,
    )


async def renumber_stops(con: asyncpg.Connection, route_id: UUID, ordered_ids: list[UUID]) -> None:
    """Give the route's active stops the sequences 1..n in `ordered_ids` order."""
    await con.execute("set constraints public.stops_route_sequence_uniq deferred")
    for seq, stop_id in enumerate(ordered_ids, start=1):
        await con.execute("update public.stops set sequence = $2 where id = $1 and sequence <> $2", stop_id, seq)
    # The uniqueness constraint is deferred; check it now rather than at the outer commit.
    await con.execute("set constraints public.stops_route_sequence_uniq immediate")
    await con.execute("set constraints public.stops_route_sequence_uniq deferred")


def place(ordered_ids: list[UUID], stop_id: UUID, sequence: int | None) -> list[UUID]:
    """`ordered_ids` with `stop_id` moved/inserted at 1-based `sequence` (None = last)."""
    ids = [i for i in ordered_ids if i != stop_id]
    index = len(ids) if sequence is None else max(0, min(sequence - 1, len(ids)))
    ids.insert(index, stop_id)
    return ids


async def _clear_polyline(con: asyncpg.Connection, route_id: UUID, error: str | None) -> None:
    await con.execute(
        """update public.routes set status = 'draft', polyline = null, cum_dist_m = null, length_m = null,
                  polyline_error = $2 where id = $1""",
        route_id, error,
    )
    await con.execute("update public.stops set dist_along_m = null where route_id = $1", route_id)


async def regenerate_polyline(con: asyncpg.Connection, provider: RouteProvider, route_id: UUID, *,
                              actor_id: UUID) -> str | None:
    """Call the Routes API once for the route's active stops. Returns the error message, or None.

    Fewer than 2 stops is not an error: the route simply stays a draft without a polyline.
    Call this OUTSIDE a transaction so the HTTP call does not hold row locks.
    """
    stops = await active_stops(con, route_id)
    if len(stops) < 2:
        async with con.transaction():
            await _clear_polyline(con, route_id, None)
        return None
    try:
        computed = await provider.compute_route([(s["lat"], s["lng"]) for s in stops])
        points = decode_polyline(computed.encoded_polyline)
        if len(points) < 2:
            raise RoutesApiError("bad_response", "Routes API returned an empty polyline")
    except (RoutesApiError, ValueError) as exc:
        message = exc.message if isinstance(exc, RoutesApiError) else "Routes API returned an invalid polyline"
        reason = exc.reason if isinstance(exc, RoutesApiError) else "bad_polyline"
        async with con.transaction():
            await _clear_polyline(con, route_id, message[:500])
            await write_audit(con, actor_id=actor_id, action="route.polyline_failed", target_type="route",
                              target_id=route_id, meta={"reason": reason, "stops": len(stops)})
        return message
    cum = cumulative_distances(points)
    along = project_stops(points, cum, [(s["lat"], s["lng"]) for s in stops])
    async with con.transaction():
        await con.execute(
            """update public.routes set polyline = $2, cum_dist_m = $3, length_m = $4, polyline_error = null,
                      status = 'active' where id = $1""",
            route_id, computed.encoded_polyline, [round(d, 1) for d in cum], round(cum[-1], 1),
        )
        for stop, dist in zip(stops, along, strict=True):
            await con.execute("update public.stops set dist_along_m = $2 where id = $1", stop["id"], round(dist, 1))
        await write_audit(con, actor_id=actor_id, action="route.polyline_generated", target_type="route",
                          target_id=route_id, meta={"stops": len(stops), "points": len(points)})
    return None
