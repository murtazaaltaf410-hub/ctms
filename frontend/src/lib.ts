import { config } from "./config";
export const kmh = (mps = 0) => Math.round(mps * 3.6);
export const ago = (iso: string) => {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? `${s}s ago` : `${Math.round(s / 60)} min ago`;
};
export const isStale = (iso: string) => Date.now() - new Date(iso).getTime() > config.staleBusAfterMs;
export const localTime = (iso: string) =>
  new Date(iso).toLocaleTimeString("en-IN", { timeZone: config.timezone, hour: "2-digit", minute: "2-digit" });
