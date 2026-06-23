import { useEffect, useMemo } from 'react';
import { MapContainer, TileLayer, Marker, Popup, Polyline, CircleMarker, useMap } from 'react-leaflet';
import L from 'leaflet';

// Custom bus divIcon with a pulsing live ring.
const busIcon = L.divIcon({
  className: '',
  html: `<div class="live-dot" style="width:34px;height:34px;display:grid;place-items:center;">
           <div style="width:34px;height:34px;border-radius:9999px;background:#3366ff;
             display:grid;place-items:center;font-size:18px;box-shadow:0 4px 12px rgba(51,102,255,.5)">🚌</div>
         </div>`,
  iconSize: [34, 34], iconAnchor: [17, 17],
});

const stopIcon = L.divIcon({
  className: '',
  html: `<div style="width:14px;height:14px;border-radius:9999px;background:#10b981;border:2px solid #fff"></div>`,
  iconSize: [14, 14], iconAnchor: [7, 7],
});

// Smoothly recenter when the focused bus moves.
const Recenter = ({ position }) => {
  const map = useMap();
  useEffect(() => { if (position) map.panTo(position, { animate: true, duration: 0.6 }); }, [position, map]);
  return null;
};

export const LiveMap = ({ buses = [], stops = [], routePath = null, focusBusId = null, userPos = null }) => {
  const center = useMemo(() => {
    const f = buses.find((b) => b.id === focusBusId) || buses[0];
    if (f?.latitude) return [Number(f.latitude), Number(f.longitude)];
    return [34.128, 74.837]; // Hazratbal
  }, [buses, focusBusId]);

  const focusPos = useMemo(() => {
    const f = buses.find((b) => b.id === focusBusId);
    return f?.latitude ? [Number(f.latitude), Number(f.longitude)] : null;
  }, [buses, focusBusId]);

  return (
    <MapContainer center={center} zoom={12} scrollWheelZoom className="h-full w-full">
      <TileLayer
        attribution='&copy; OpenStreetMap contributors'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" />

      {routePath && Array.isArray(routePath) && (
        <Polyline positions={routePath.map((p) => [p[0], p[1]])}
          pathOptions={{ color: '#3366ff', weight: 4, opacity: 0.6 }} />
      )}

      {stops.map((s) => (
        <Marker key={`stop-${s.id}`} position={[Number(s.latitude), Number(s.longitude)]} icon={stopIcon}>
          <Popup><b>{s.name}</b><br />Stop #{s.stop_order} · +{s.eta_offset_min} min</Popup>
        </Marker>
      ))}

      {buses.filter((b) => b.latitude).map((b) => (
        <Marker key={`bus-${b.id}`} position={[Number(b.latitude), Number(b.longitude)]} icon={busIcon}>
          <Popup>
            <b>{b.label}</b><br />
            {b.route_name || 'No route'}<br />
            Status: {b.status} · {b.occupancy}
          </Popup>
        </Marker>
      ))}

      {userPos && (
        <CircleMarker center={userPos} radius={8}
          pathOptions={{ color: '#0ea5e9', fillColor: '#0ea5e9', fillOpacity: 0.8 }}>
          <Popup>You are here</Popup>
        </CircleMarker>
      )}

      <Recenter position={focusPos} />
    </MapContainer>
  );
};
