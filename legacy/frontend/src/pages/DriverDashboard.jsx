import { useEffect, useRef, useState } from 'react';
import { api } from '../api/client.js';
import { useAuth } from '../context/AuthContext.jsx';
import { LiveMap } from '../components/LiveMap.jsx';
import { Card, Button, StatusBadge } from '../components/ui.jsx';

const STATUSES = [
  { key: 'on_time', label: 'On time', variant: 'success' },
  { key: 'delayed', label: 'Delayed', variant: 'primary' },
  { key: 'breakdown', label: 'Breakdown', variant: 'danger' },
  { key: 'completed', label: 'Journey done', variant: 'ghost' },
];
const OCCUPANCIES = ['available', 'moderate', 'full'];

export default function DriverDashboard() {
  const { user } = useAuth();
  const [bus, setBus] = useState(null);
  const [sharing, setSharing] = useState(false);
  const [pos, setPos] = useState(null);
  const [status, setStatus] = useState('idle');
  const [occupancy, setOccupancy] = useState('available');
  const [lastSent, setLastSent] = useState(null);
  const watchId = useRef(null);

  // Find this driver's assigned bus (buses list includes it; match later by detail)
  useEffect(() => {
    (async () => {
      const { data } = await api.get('/buses');
      // Heuristic: drivers see all buses; assigned one resolved server-side on push.
      setBus(data.buses[0] || null);
      if (data.buses[0]) { setStatus(data.buses[0].status); setOccupancy(data.buses[0].occupancy); }
    })();
  }, []);

  const pushLocation = async (coords) => {
    try {
      await api.post('/tracking/location', {
        latitude: coords.latitude, longitude: coords.longitude,
        speed: coords.speed ? coords.speed * 3.6 : null, // m/s -> km/h
        heading: coords.heading ?? null,
      });
      setLastSent(new Date());
    } catch { /* surfaced via toast normally */ }
  };

  const startSharing = () => {
    if (!navigator.geolocation) return alert('Geolocation not supported');
    setSharing(true);
    watchId.current = navigator.geolocation.watchPosition(
      (p) => {
        const c = p.coords;
        setPos([c.latitude, c.longitude]);
        pushLocation(c);
      },
      (err) => { console.error(err); },
      { enableHighAccuracy: true, maximumAge: 2000, timeout: 10000 }
    );
  };

  const stopSharing = () => {
    if (watchId.current != null) navigator.geolocation.clearWatch(watchId.current);
    watchId.current = null;
    setSharing(false);
  };

  useEffect(() => () => stopSharing(), []);

  const changeStatus = async (s) => {
    setStatus(s);
    await api.post('/tracking/status', { status: s });
  };
  const changeOccupancy = async (o) => {
    setOccupancy(o);
    await api.post('/tracking/status', { occupancy: o });
  };

  const mapBuses = pos ? [{ id: bus?.id || 0, label: bus?.label || 'Your bus',
    latitude: pos[0], longitude: pos[1], status, occupancy, route_name: bus?.route_name }] : [];

  return (
    <div className="grid lg:grid-cols-3 gap-5">
      <div className="lg:col-span-2 space-y-5">
        <Card className="p-0 overflow-hidden h-[420px]">
          <LiveMap buses={mapBuses} focusBusId={bus?.id || 0} userPos={pos} />
        </Card>
        <Card>
          <div className="flex items-center justify-between flex-wrap gap-3">
            <div>
              <div className="text-sm text-slate-500">GPS sharing</div>
              <div className="font-bold text-lg flex items-center gap-2">
                {sharing
                  ? <><span className="w-2.5 h-2.5 rounded-full bg-emerald-500 animate-pulse" /> Live</>
                  : <><span className="w-2.5 h-2.5 rounded-full bg-slate-400" /> Off</>}
              </div>
              {lastSent && <div className="text-xs text-slate-400 mt-1">Last fix: {lastSent.toLocaleTimeString()}</div>}
            </div>
            {sharing
              ? <Button variant="danger" onClick={stopSharing}>End journey</Button>
              : <Button variant="success" onClick={startSharing}>Start journey & share GPS</Button>}
          </div>
        </Card>
      </div>

      <div className="space-y-5">
        <Card>
          <div className="text-sm text-slate-500">Driver</div>
          <div className="font-bold text-lg">{user.fullName}</div>
          <div className="mt-3 text-sm text-slate-500">Assigned bus</div>
          <div className="font-semibold">{bus?.label || '—'}</div>
          <div className="text-xs text-slate-400">{bus?.route_name || ''}</div>
          <div className="mt-3"><StatusBadge status={status} /></div>
        </Card>

        <Card>
          <h3 className="font-bold mb-3">Update status</h3>
          <div className="grid grid-cols-2 gap-2">
            {STATUSES.map((s) => (
              <Button key={s.key} variant={status === s.key ? s.variant : 'ghost'}
                onClick={() => changeStatus(s.key)}>{s.label}</Button>
            ))}
          </div>
        </Card>

        <Card>
          <h3 className="font-bold mb-3">Occupancy</h3>
          <div className="grid grid-cols-3 gap-2">
            {OCCUPANCIES.map((o) => (
              <Button key={o} variant={occupancy === o ? 'primary' : 'ghost'}
                onClick={() => changeOccupancy(o)} className="capitalize text-sm">{o}</Button>
            ))}
          </div>
        </Card>
      </div>
    </div>
  );
}
