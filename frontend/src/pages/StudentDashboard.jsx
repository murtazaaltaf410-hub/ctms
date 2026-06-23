import { useEffect, useState, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { api } from '../api/client.js';
import { useSocket } from '../hooks/useSocket.js';
import { LiveMap } from '../components/LiveMap.jsx';
import { Card, Skeleton, StatusBadge, OccupancyTag } from '../components/ui.jsx';

export default function StudentDashboard() {
  const [buses, setBuses] = useState([]);
  const [loading, setLoading] = useState(true);
  const [focusId, setFocusId] = useState(null);
  const [stops, setStops] = useState([]);
  const [routePath, setRoutePath] = useState(null);
  const [eta, setEta] = useState(null);
  const [userPos, setUserPos] = useState(null);
  const [announcements, setAnnouncements] = useState([]);
  const socketRef = useSocket(true);

  // Initial load
  useEffect(() => {
    (async () => {
      try {
        const [{ data: b }, { data: a }] = await Promise.all([
          api.get('/buses'), api.get('/announcements'),
        ]);
        setBuses(b.buses);
        setAnnouncements(a.announcements);
        if (b.buses[0]) setFocusId(b.buses[0].id);
      } finally { setLoading(false); }
    })();
  }, []);

  // User geolocation (for ETA + "you are here")
  useEffect(() => {
    if (!navigator.geolocation) return;
    navigator.geolocation.getCurrentPosition(
      (p) => setUserPos([p.coords.latitude, p.coords.longitude]),
      () => setUserPos([34.128, 74.837]), // fallback: campus gate
      { enableHighAccuracy: true, timeout: 8000 }
    );
  }, []);

  // Realtime: live locations + status + announcements
  useEffect(() => {
    const socket = socketRef.current;
    if (!socket) return;
    const onLoc = (p) => setBuses((prev) => prev.map((b) =>
      b.id === p.busId ? { ...b, latitude: p.latitude, longitude: p.longitude,
        speed_kmh: p.speed, heading: p.heading } : b));
    const onStatus = (p) => setBuses((prev) => prev.map((b) =>
      b.id === p.busId ? { ...b, status: p.status ?? b.status, occupancy: p.occupancy ?? b.occupancy } : b));
    const onAnn = (a) => setAnnouncements((prev) => [a, ...prev]);
    socket.on('bus:location', onLoc);
    socket.on('bus:status', onStatus);
    socket.on('announcement:new', onAnn);
    return () => { socket.off('bus:location', onLoc); socket.off('bus:status', onStatus); socket.off('announcement:new', onAnn); };
  }, [socketRef.current]);

  // Load focused bus route + stops, subscribe to its channel
  const selectBus = useCallback(async (id) => {
    setFocusId(id);
    socketRef.current?.emit('bus:subscribe', id);
    try {
      const { data } = await api.get(`/buses/${id}`);
      setStops(data.stops || []);
      setRoutePath(data.bus?.route_path || null);
    } catch { setStops([]); setRoutePath(null); }
  }, [socketRef]);

  useEffect(() => { if (focusId) selectBus(focusId); /* eslint-disable-next-line */ }, [focusId]);

  // Recompute ETA whenever the focused bus moves or user moves
  useEffect(() => {
    if (!focusId || !userPos) return;
    const t = setTimeout(async () => {
      try {
        const { data } = await api.get('/tracking/eta', {
          params: { busId: focusId, lat: userPos[0], lng: userPos[1] },
        });
        setEta(data);
      } catch { setEta(null); }
    }, 400);
    return () => clearTimeout(t);
  }, [focusId, userPos, buses]);

  const focusBus = buses.find((b) => b.id === focusId);

  return (
    <div className="grid lg:grid-cols-3 gap-5">
      <div className="lg:col-span-2 space-y-5">
        <Card className="p-0 overflow-hidden h-[460px]">
          {loading
            ? <Skeleton className="h-full w-full" />
            : <LiveMap buses={buses} stops={stops} routePath={routePath}
                focusBusId={focusId} userPos={userPos} />}
        </Card>

        {focusBus && (
          <div className="grid sm:grid-cols-3 gap-4">
            <Card><div className="text-xs text-slate-500">Distance remaining</div>
              <div className="text-2xl font-bold mt-1">{eta ? `${eta.distanceKm} km` : '—'}</div></Card>
            <Card><div className="text-xs text-slate-500">Estimated arrival</div>
              <div className="text-2xl font-bold mt-1 text-brand-500">{eta ? `${eta.etaMinutes} min` : '—'}</div></Card>
            <Card><div className="text-xs text-slate-500">Current status</div>
              <div className="mt-2"><StatusBadge status={focusBus.status} /></div></Card>
          </div>
        )}
      </div>

      <div className="space-y-5">
        <Card>
          <h3 className="font-bold mb-3">Active buses</h3>
          <div className="space-y-2">
            {loading
              ? Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-16 w-full" />)
              : buses.map((b) => (
                <button key={b.id} onClick={() => setFocusId(b.id)}
                  className={`w-full text-left p-3 rounded-xl border transition
                    ${focusId === b.id
                      ? 'border-brand-500 bg-brand-500/10'
                      : 'border-slate-200 dark:border-white/10 hover:bg-slate-100 dark:hover:bg-white/5'}`}>
                  <div className="flex items-center justify-between">
                    <div className="font-semibold">{b.label}</div>
                    <StatusBadge status={b.status} />
                  </div>
                  <div className="flex items-center justify-between mt-1">
                    <span className="text-xs text-slate-500">{b.route_name || 'No route'}</span>
                    <OccupancyTag occupancy={b.occupancy} />
                  </div>
                </button>
              ))}
          </div>
        </Card>

        <Card>
          <h3 className="font-bold mb-3">Announcements</h3>
          <div className="space-y-3 max-h-72 overflow-auto pr-1">
            <AnimatePresence>
              {announcements.map((a) => (
                <motion.div key={a.id} initial={{ opacity: 0, x: 12 }} animate={{ opacity: 1, x: 0 }}
                  className="p-3 rounded-xl bg-slate-100 dark:bg-white/5">
                  <div className="flex items-center gap-2">
                    <span className={`w-2 h-2 rounded-full ${
                      a.severity === 'critical' ? 'bg-rose-500'
                      : a.severity === 'warning' ? 'bg-amber-500' : 'bg-brand-500'}`} />
                    <span className="font-semibold text-sm">{a.title}</span>
                  </div>
                  <p className="text-xs text-slate-500 mt-1">{a.body}</p>
                </motion.div>
              ))}
            </AnimatePresence>
            {announcements.length === 0 && <p className="text-sm text-slate-400">No announcements yet.</p>}
          </div>
        </Card>
      </div>
    </div>
  );
}
