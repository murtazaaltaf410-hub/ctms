import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../auth/authStore";
export default function Layout() {
  const { user, logout } = useAuth();
  return (
    <>
      <header className="top">
        <b>CTMS</b>
        <nav className="tabs">
          <NavLink to="/map">Map</NavLink><NavLink to="/routes">Routes</NavLink><NavLink to="/announcements">News</NavLink>
          {user?.role === "driver" && <NavLink to="/driver">Trip</NavLink>}
          {user?.role === "admin" && <NavLink to="/admin">Admin</NavLink>}
        </nav>
        <span className="muted">{user?.name}</span>
        <button className="ghost" onClick={logout}>Sign out</button>
      </header>
      <Outlet />
    </>
  );
}
