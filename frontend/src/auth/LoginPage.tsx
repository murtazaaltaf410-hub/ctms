import { useState, type FormEvent } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "./authStore";
import { ApiError } from "../api/client";

const MESSAGES: Record<string, string> = {
  INVALID_CREDENTIALS: "That user ID or password isn't right.",
  RATE_LIMITED: "Too many attempts.",
};

export default function LoginPage() {
  const { user, login, notice } = useAuth();
  const [id, setId] = useState(""); const [pw, setPw] = useState("");
  const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  if (user) return <Navigate to="/" replace />;

  async function submit(e: FormEvent) {
    e.preventDefault(); setBusy(true); setErr(null);
    try { await login(id.trim(), pw); }
    catch (x) {
      const a = x as ApiError;
      setErr((MESSAGES[a.code] ?? a.message) + (a.retryAfter ? ` Try again in ${a.retryAfter}s.` : ""));
    } finally { setBusy(false); }
  }
  return (
    <main className="login">
      <h1>Where's my bus?</h1>
      <p className="muted">University of Kashmir, North Campus</p>
      {notice && <p className="banner">{notice}</p>}
      <form onSubmit={submit}>
        <label>User ID, email or phone<input value={id} onChange={(e) => setId(e.target.value)} autoComplete="username" required /></label>
        <label>Password<input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="current-password" required /></label>
        {err && <p className="error" role="alert">{err}</p>}
        <button disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
      </form>
    </main>
  );
}
