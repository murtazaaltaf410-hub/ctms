import { useEffect, useState } from "react";
import { APIProvider, Map, AdvancedMarker, InfoWindow, Pin } from "@vis.gl/react-google-maps";
import { config } from "../../config";
import { listAll } from "../../api/client";
import { paths } from "../../api/endpoints";
import type { RouteDto } from "../../api/types";
import { useLive } from "../../live/liveStore";
import { useLiveBuses } from "../../live/useLiveBuses";
import { ago, isStale, kmh } from "../../lib";

export default function MapPage() {
  useLiveBuses();
  const { buses, status } = useLive();
  const [routes, setRoutes] = useState<RouteDto[]>([]);
  const [sel, setSel] = useState<string | null>(null);
  const [, tick] = useState(0);
  useEffect(() => { listAll<RouteDto>(paths.routes).then(setRoutes).catch(() => {}); }, []);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 5000); return () => clearInterval(t); }, []);

  const list = Object.values(buses);
  const bus = sel ? buses[sel] : null;
  if (!config.mapsKey) return <p className="center error">Set VITE_GOOGLE_MAPS_KEY in .env to show the map.</p>;

  return (
    <div className="mapwrap">
      <div className={`pill ${status}`}>
        {status === "live" ? "Live" : status === "connecting" ? "Connecting…" : "Reconnecting, showing last known positions"}
      </div>
      {list.length === 0 && <div className="pill empty">No buses are running right now.</div>}
      <APIProvider apiKey={config.mapsKey}>
        <Map mapId="DEMO_MAP_ID" defaultCenter={config.campusCenter} defaultZoom={config.campusZoom} gestureHandling="greedy" disableDefaultUI>
          {routes.flatMap((r) => r.stops ?? []).map((s) => (
            <AdvancedMarker key={s.id} position={s} title={s.name}>
              <Pin background="#1F5C7A" borderColor="#fff" glyphColor="#fff" scale={0.7} />
            </AdvancedMarker>
          ))}
          {list.map((b) => (
            <AdvancedMarker key={b.bus_id} position={{ lat: b.lat, lng: b.lng }} onClick={() => setSel(b.bus_id)}>
              <Pin background={isStale(b.updated_at) ? "#9AA5A0" : "#E0A030"} borderColor="#14231F" glyphColor="#14231F" glyph="B" />
            </AdvancedMarker>
          ))}
          {bus && (
            <InfoWindow position={{ lat: bus.lat, lng: bus.lng }} onCloseClick={() => setSel(null)}>
              <strong>Bus {bus.bus_id.slice(0, 6)}</strong><br />
              {kmh(bus.speed_mps)} km/h · updated {ago(bus.updated_at)}
              {isStale(bus.updated_at) && <><br />Signal lost</>}
            </InfoWindow>
          )}
        </Map>
      </APIProvider>
    </div>
  );
}
