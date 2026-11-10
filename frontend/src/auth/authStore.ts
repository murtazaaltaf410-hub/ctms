import { create } from "zustand";
import { get, post, session, ApiError } from "../api/client";
import { paths } from "../api/endpoints";
import type { LoginResponse, User } from "../api/types";

interface AuthState {
  user: User | null; ready: boolean; notice: string | null;
  init(): Promise<void>; login(identifier: string, password: string): Promise<void>; logout(): Promise<void>;
}

export const useAuth = create<AuthState>((set) => ({
  user: null, ready: false, notice: null,
  async init() {
    session.onExpire = () => set({ user: null, notice: "You were signed out. Sign in again to continue." });
    if (session.refresh) {
      try {
        // A bare call triggers 401 -> refresh -> retry inside the client.
        set({ user: await get<User>(paths.me) });
      } catch (e) {
        if (e instanceof ApiError && e.code === "SESSION_REPLACED")
          set({ notice: "You signed in on another device, so this session ended." });
      }
    }
    set({ ready: true });
  },
  async login(identifier, password) {
    const r = await post<LoginResponse>(paths.login, { identifier, password });
    session.set(r); set({ user: r.user, notice: null });
  },
  async logout() {
    try { await post(paths.logout, { refresh_token: session.refresh }); } catch { /* best effort */ }
    session.clear(); set({ user: null });
  },
}));
