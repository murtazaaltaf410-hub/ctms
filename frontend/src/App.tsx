import { useEffect } from "react";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { useAuth } from "./auth/authStore";
import { RequireRole } from "./auth/RequireRole";
import LoginPage from "./auth/LoginPage";
import Layout from "./components/Layout";
import MapPage from "./features/student/MapPage";
import { RoutesPage, AnnouncementsPage } from "./features/student/InfoPage";
import AdminPage from "./features/admin/AdminPage";
import DriverPage from "./features/driver/DriverPage";

function Home() {
  const { user } = useAuth();
  return <Navigate to={user ? "/map" : "/login"} replace />;
}

export default function App() {
  const init = useAuth((s) => s.init);
  useEffect(() => { init(); }, [init]);
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route element={<RequireRole roles={["student", "driver", "admin"]}><Layout /></RequireRole>}>
          <Route path="/map" element={<MapPage />} />
          <Route path="/routes" element={<RoutesPage />} />
          <Route path="/announcements" element={<AnnouncementsPage />} />
          <Route path="/driver/*" element={<RequireRole roles={["driver"]}><DriverPage /></RequireRole>} />
          <Route path="/admin/*" element={<RequireRole roles={["admin"]}><AdminPage /></RequireRole>} />
        </Route>
        <Route path="*" element={<Home />} />
      </Routes>
    </BrowserRouter>
  );
}
