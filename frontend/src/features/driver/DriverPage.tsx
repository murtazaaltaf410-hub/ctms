import { useEffect, useRef, useState } from "react";
import { api, listAll, post, ApiError } from "../../api/client";
import { paths } from "../../api/endpoints";
import type { RouteDto } from "../../api/types";

const FLUSH_MS = 5000, MAX_BATCH = 20; // API allows <=20 fixes per request
interface Fix { fix_id: string; lat: number; lng: number; speed_mps?: number; heading?: number; recorded_at: string }

export default function DriverPage() {
  const [routes, setRoutes] = useState<RouteDto[]>([]);
  const [routeId, setRouteId] = useState(""); const [busId, setBusId] = useState("");
  const [tripId, setTripId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null); const [sent, setSent] = useState(0);
  const buf = useRef<Fix[]>([]); const wake = useRef<{ release(): Promise<void> } | null>(null);
  useEffect(() => { listAll<RouteDto>(paths.routes).then((r) => { setRoutes(r); setRouteId(r[0]?.id ?? ""); }).catch(() => {}); }, []);

  useEffect(() => {
    if (!tripId) return;
    const w = navigator.geolocation.watchPosition(
      (p) => buf.current.push({ fix_id: crypto.randomUUID(), lat: p.coords.latitude, lng: p.coords.longitude, speed_mps: p.coords.speed ?? undefined, heading: p.coords.heading ?? undefined, recorded_at: new Date(p.timestamp).toISOString() }),
      () => setErr("Location is blocked. Allow location access for this site."), { enableHighAccuracy: true });
    const t = setInterval(async () => {
      const batch = buf.current.splice(0, MAX_BATCH);
      if (!batch.length) return;
      try { await post(paths.tripFixes(tripId), { fixes: batch }); setSent((n) => n + batch.length); }
      catch { buf.current.unshift(...batch); } // keep for retry
    }, FLUSH_MS);
    return () => { navigator.geolocation.clearWatch(w); clearInterval(t); };
  }, [tripId]);

  async function start() {
    setErr(null);
    try {
      const trip = await post<{ id: string }>(paths.trips, { route_id: routeId, bus_id: busId || undefined });
      setTripId(trip.id); setSent(0);
      try { wake.current = await (navigator as unknown as { wakeLock: { request(t: string): Promise<{ release(): Promise<void> }> } }).wakeLock.request("screen"); } catch { /* unsupported */ }
    } catch (x) { setErr((x as ApiError).message); }
  }
  async function stop() {
    if (!tripId) return;
    try { await api(paths.endTrip(tripId), { method: "POST" }); } catch (x) { setErr((x as ApiError).message); return; }
    wake.current?.release(); setTripId(null);
  }
  return (
    <div className="page"><h2>Trip</h2>
      <p className="banner">Keep this tab open and the screen on. Location stops sending when the tab is in the background. For all-day driving, use the Android app.</p>
      {err && <p className="error" role="alert">{err}</p>}
      {!tripId ? (
        <div className="card">
          <label>Route<select value={routeId} onChange={(e) => setRouteId(e.target.value)}>{routes.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
          <label>Bus ID (if required)<input value={busId} onChange={(e) => setBusId(e.target.value)} /></label>
          <button onClick={start} disabled={!routeId}>Start trip</button>
        </div>
      ) : (
        <div className="card"><p>Trip in progress. Location updates sent: <b>{sent}</b></p><button onClick={stop}>End trip</button></div>
      )}
    </div>
  );
}
