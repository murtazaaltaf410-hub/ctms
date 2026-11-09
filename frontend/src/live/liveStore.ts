import { create } from "zustand";
import type { BusFix } from "../api/types";
interface LiveState { buses: Record<string, BusFix>; status: "connecting" | "live" | "offline"; upsert(f: BusFix): void; setStatus(s: LiveState["status"]): void }
export const useLive = create<LiveState>((set) => ({
  buses: {}, status: "offline",
  upsert: (f) => set((s) => ({ buses: { ...s.buses, [f.bus_id]: f } })),
  setStatus: (status) => set({ status }),
}));
