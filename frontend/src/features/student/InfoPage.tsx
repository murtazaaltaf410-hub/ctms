import { useEffect, useState } from "react";
import { get, listAll } from "../../api/client";
import { paths } from "../../api/endpoints";
import type { RouteDto, Stop } from "../../api/types";
import { localTime } from "../../lib";

interface Eta { bus_id: string; eta_seconds: number }
interface Announcement { id: string; title: string; body: string; created_at: string }
const mins = (s: number) => (s < 60 ? "Arriving" : `${Math.round(s / 60)} min`);

export function RoutesPage() {
  const [routes, setRoutes] = useState<RouteDto[]>([]);
  const [stop, setStop] = useState<Stop | null>(null);
  const [etas, setEtas] = useState<Eta[] | null>(null);
  useEffect(() => { listAll<RouteDto>(paths.routes).then(setRoutes).catch(() => {}); }, []);
  useEffect(() => {
    if (!stop) return;
    const load = () => get<{ items: Eta[] } | Eta[]>(paths.stopEtas(stop.id)).then((r) => setEtas(Array.isArray(r) ? r : r.items)).catch(() => setEtas([]));
    setEtas(null); load(); const t = setInterval(load, 15000); return () => clearInterval(t);
  }, [stop]);
  return (
    <div className="page">
      <h2>Routes and stops</h2>
      {routes.length === 0 && <p className="muted">No routes yet.</p>}
      {routes.map((r) => (
        <div key={r.id} className="card"><h3>{r.name}</h3>
          <div className="chips">{(r.stops ?? []).map((s) => <button key={s.id} className={stop?.id === s.id ? "" : "ghost"} onClick={() => setStop(s)}>{s.name}</button>)}</div>
        </div>
      ))}
      {stop && (
        <div className="card"><h3>Next buses at {stop.name}</h3>
          {etas === null ? <p className="muted">Loading…</p> : etas.length === 0 ? <p className="muted">No buses are heading here right now.</p>
            : <ul>{etas.map((e) => <li key={e.bus_id}>Bus {e.bus_id.slice(0, 6)}: <b>{mins(e.eta_seconds)}</b></li>)}</ul>}
        </div>
      )}
    </div>
  );
}

export function AnnouncementsPage() {
  const [items, setItems] = useState<Announcement[] | null>(null);
  useEffect(() => { listAll<Announcement>(paths.announcements).then(setItems).catch(() => setItems([])); }, []);
  return (
    <div className="page"><h2>Announcements</h2>
      {items === null ? <p className="muted">Loading…</p> : items.length === 0 ? <p className="muted">No announcements.</p>
        : items.map((a) => <article key={a.id} className="card"><h3>{a.title}</h3><p>{a.body}</p><small className="muted">{localTime(a.created_at)}</small></article>)}
    </div>
  );
}
