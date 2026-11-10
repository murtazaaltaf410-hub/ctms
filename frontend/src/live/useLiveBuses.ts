import { useEffect } from "react";
import { config } from "../config";
import { get, session } from "../api/client";
import { paths } from "../api/endpoints";
import type { BusFix } from "../api/types";
import { useLive } from "./liveStore";

// Opens /ws/live, sends the auth message first (token never in URL), sends a 25s
// heartbeat, reconnects with backoff + jitter, and polls REST while down.
export function useLiveBuses() {
  useEffect(() => {
    const { upsert, setStatus } = useLive.getState();
    const remove = (useLive.getState() as { remove?: (busId: string) => void }).remove;
    let ws: WebSocket | null = null;
    let stopped = false;
    let tries = 0;
    let retry: number | undefined;
    let poll: number | undefined;
    let heartbeat: number | undefined;

    const snapshot = async () => {
      try {
        const r = await get<{ items: BusFix[] } | BusFix[]>(paths.liveBuses);
        (Array.isArray(r) ? r : r.items).forEach(upsert);
      } catch {
        /* shown via status */
      }
    };

    const connect = () => {
      if (stopped) return;
      setStatus("connecting");
      ws = new WebSocket(config.wsUrl);

      ws.onopen = () => {
        ws?.send(JSON.stringify({ type: "auth", token: session.access }));
        tries = 0;
        setStatus("live");
        clearInterval(poll);
        heartbeat = window.setInterval(() => {
          if (ws?.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "ping" }));
          }
        }, 25_000);
      };

      ws.onmessage = (ev) => {
        try {
          const m = JSON.parse(ev.data) as Record<string, unknown>;
          const type = m.type as string | undefined;

          if (type === "auth_ok" || type === "ready" || type === "pong") {
            tries = 0;
            setStatus("live");
            clearInterval(poll);
          } else if (type === "bus_position") {
            upsert({
              bus_id: String(m.bus_id),
              trip_id: m.trip_id ? String(m.trip_id) : undefined,
              lat: Number(m.lat),
              lng: Number(m.lng),
              heading: typeof m.heading === "number" ? m.heading : undefined,
              speed: typeof m.speed === "number" ? m.speed : undefined,
              speed_mps: typeof m.speed === "number" ? m.speed : undefined,
              recorded_at: m.recorded_at ? String(m.recorded_at) : undefined,
              updated_at: m.recorded_at ? String(m.recorded_at) : new Date().toISOString(),
              state: "live",
            });
          } else if (type === "bus_status") {
            const busId = String(m.bus_id);
            const existing = useLive.getState().buses?.[busId];
            if (existing) {
              upsert({
                ...existing,
                status: m.status ? String(m.status) : existing.status,
                note: m.note !== undefined ? (m.note as string | null) : existing.note,
                updated_at: new Date().toISOString(),
              });
            }
          } else if (type === "trip_started") {
            void snapshot();
          } else if (type === "trip_ended") {
            const busId = String(m.bus_id);
            if (remove) {
              remove(busId);
            } else {
              const existing = useLive.getState().buses?.[busId];
              if (existing) {
                upsert({ ...existing, state: "offline", updated_at: new Date().toISOString() });
              }
            }
          }
        } catch {
          /* ignore malformed */
        }
      };

      ws.onclose = () => {
        clearInterval(heartbeat);
        if (stopped) return;
        setStatus("offline");
        poll = window.setInterval(snapshot, config.pollFallbackMs);
        const delay =
          Math.min(config.ws.backoffBaseMs * 2 ** tries++, config.ws.backoffMaxMs) *
          (0.5 + Math.random() / 2);
        retry = window.setTimeout(connect, delay);
      };
    };

    void snapshot();
    connect();

    const vis = () => {
      if (!document.hidden && ws?.readyState !== WebSocket.OPEN) {
        tries = 0;
        void snapshot();
      }
    };
    document.addEventListener("visibilitychange", vis);

    return () => {
      stopped = true;
      clearTimeout(retry);
      clearInterval(poll);
      clearInterval(heartbeat);
      document.removeEventListener("visibilitychange", vis);
      ws?.close();
    };
  }, []);
}
