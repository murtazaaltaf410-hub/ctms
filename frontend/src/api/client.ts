import { config } from "../config";
import { paths } from "./endpoints";
import type { Page, TokenPair } from "./types";

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public retryAfter?: number) {
    super(message);
  }
}

// Session lives here (not in React) so the client can refresh without hooks.
let access: string | null = null;
const RT_KEY = "ctms_rt";
export const session = {
  get access() { return access; },
  get refresh() { try { return localStorage.getItem(RT_KEY); } catch { return null; } },
  set(t: TokenPair) {
    access = t.access_token;
    try { localStorage.setItem(RT_KEY, t.refresh_token); } catch { /* storage blocked */ }
  },
  clear() { access = null; try { localStorage.removeItem(RT_KEY); } catch { /* ignore */ } },
  onExpire: () => {},
};

let refreshing: Promise<boolean> | null = null;
function refreshOnce(): Promise<boolean> {
  refreshing ??= (async () => {
    const rt = session.refresh;
    if (!rt) return false;
    try {
      const res = await fetch(config.apiBase + paths.refresh, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: rt }), // body, not cookie (API spec)
      });
      if (!res.ok) return false;
      session.set(await res.json());
      return true;
    } catch { return false; }
    finally { setTimeout(() => (refreshing = null), 0); }
  })();
  return refreshing;
}

async function parseError(res: Response): Promise<ApiError> {
  let code = "UNKNOWN", message = res.statusText;
  try { const j = await res.json(); code = j.error?.code ?? code; message = j.error?.message ?? message; } catch { /* non-JSON */ }
  const ra = Number(res.headers.get("Retry-After")) || undefined;
  return new ApiError(res.status, code, message, ra);
}

export async function api<T>(path: string, init: RequestInit = {}, retried = false, attempt = 0): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body) headers.set("Content-Type", "application/json");
  if (access) headers.set("Authorization", `Bearer ${access}`);
  let res: Response;
  try {
    res = await fetch(config.apiBase + path, { ...init, headers });
  } catch (e) {
    // Render free tier cold start: back off and retry before surfacing an error.
    if (attempt < config.coldStartRetries) {
      await new Promise((r) => setTimeout(r, 2000 * 2 ** attempt));
      return api<T>(path, init, retried, attempt + 1);
    }
    throw new ApiError(0, "NETWORK", "Can't reach the server. Check your connection and try again.");
  }
  if (res.status === 401 && !retried && path !== paths.login) {
    if (await refreshOnce()) return api<T>(path, init, true, attempt);
    session.clear(); session.onExpire();
  }
  if (!res.ok) {
    const err = await parseError(res);
    if (err.code === "SESSION_REPLACED") { session.clear(); session.onExpire(); }
    throw err;
  }
  return res.status === 204 ? (undefined as T) : res.json();
}

export const get = <T,>(p: string) => api<T>(p);
export const post = <T,>(p: string, body?: unknown) => api<T>(p, { method: "POST", body: body ? JSON.stringify(body) : undefined });

export async function listAll<T>(path: string): Promise<T[]> {
  const out: T[] = []; let cursor: string | null = null;
  do {
    const q: string = `${path}${path.includes("?") ? "&" : "?"}limit=200${cursor ? `&cursor=${cursor}` : ""}`;
    const page: Page<T> = await get<Page<T>>(q);
    out.push(...page.items); cursor = page.next_cursor;
  } while (cursor);
  return out;
}
