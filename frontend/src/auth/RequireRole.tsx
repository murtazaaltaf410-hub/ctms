import { Navigate } from "react-router-dom";
import { useAuth } from "./authStore";
import type { Role } from "../api/types";

// UX guard only: the server re-checks the role on every request.
export function RequireRole({ roles, children }: { roles: Role[]; children: JSX.Element }) {
  const { user, ready } = useAuth();
  if (!ready) return <p className="center">Loading…</p>;
  if (!user) return <Navigate to="/login" replace />;
  if (!roles.includes(user.role)) return <Navigate to="/" replace />;
  return children;
}
