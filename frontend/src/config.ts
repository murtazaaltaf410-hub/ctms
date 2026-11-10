// Single home for every constant/threshold (project rule: no literals in code).
const api = (import.meta.env.VITE_API_BASE_URL as string) || "http://localhost:8000";
export const config = {
  apiBase: `${api}/api/v1`,
  wsUrl: `${api.replace(/^http/, "ws")}/api/v1/ws/live`,
  mapsKey: (import.meta.env.VITE_GOOGLE_MAPS_KEY as string) || "",
  campusCenter: { lat: 34.1293, lng: 74.8398 }, // North Campus, Univ. of Kashmir (adjust)
  campusZoom: 15,
  timezone: "Asia/Kolkata",
  ws: { authTimeoutMs: 5000, backoffBaseMs: 1000, backoffMaxMs: 30000 },
  staleBusAfterMs: 60_000,
  pollFallbackMs: 10_000,
  coldStartRetries: 3,
};
