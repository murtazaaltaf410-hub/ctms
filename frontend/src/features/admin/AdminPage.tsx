import { NavLink, Navigate, Route, Routes } from "react-router-dom";
import Crud, { type Field } from "../../components/Crud";
import { paths } from "../../api/endpoints";

const t = (key: string, label: string, required = true): Field => ({ key, label, required });

const modules: { to: string; label: string; path: string; fields: Field[]; readOnly?: boolean }[] = [
  {
    to: "buses",
    label: "Buses",
    path: paths.buses,
    fields: [
      t("label", "Bus label"),
      t("plate", "Plate number"),
      { key: "capacity", label: "Capacity", type: "number" },
    ],
  },
  {
    to: "drivers",
    label: "Drivers",
    path: paths.drivers,
    fields: [
      t("name", "Name"),
      t("userid", "User ID", false),
      t("phone", "Phone (+E.164)", false),
      t("email", "Email", false),
      t("bus_id", "Bus ID", false),
    ],
  },
  {
    to: "routes",
    label: "Routes",
    path: paths.adminRoutes,
    fields: [t("name", "Route name")],
  },
  {
    to: "stops",
    label: "Stops",
    path: paths.stops,
    fields: [
      t("route_id", "Route ID"),
      t("name", "Stop name"),
      { key: "lat", label: "Latitude", type: "number", required: true },
      { key: "lng", label: "Longitude", type: "number", required: true },
      { key: "sequence", label: "Sequence order", type: "number", required: true },
    ],
  },
  {
    to: "schedules",
    label: "Schedules",
    path: paths.schedulesAdmin,
    fields: [
      t("route_id", "Route ID"),
      t("departure_time", "Departure time (HH:MM)"),
      t("days_of_week", "Days of week (e.g. 0,1,2,3,4)"),
    ],
  },
  {
    to: "announcements",
    label: "Announcements",
    path: paths.announcementsAdmin,
    fields: [
      t("title", "Title"),
      { key: "body", label: "Message", type: "textarea", required: true },
    ],
  },
  {
    to: "reports",
    label: "Reports",
    path: paths.reports,
    readOnly: true,
    fields: [
      t("bus_label", "Bus"),
      t("driver_name", "Driver"),
      t("route_name", "Route"),
      t("direction", "Direction"),
      t("started_at", "Started"),
      t("ended_at", "Ended"),
      t("closed_by", "Closed by"),
    ],
  },
];

export default function AdminPage() {
  return (
    <div className="admin">
      <nav>
        {modules.map((m) => (
          <NavLink key={m.to} to={m.to}>
            {m.label}
          </NavLink>
        ))}
      </nav>
      <div className="content">
        <Routes>
          <Route index element={<Navigate to="buses" replace />} />
          {modules.map((m) => (
            <Route
              key={m.to}
              path={m.to}
              element={<Crud title={m.label} path={m.path} fields={m.fields} readOnly={m.readOnly} />}
            />
          ))}
        </Routes>
      </div>
    </div>
  );
}
