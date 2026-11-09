// All paths matched to CTMS V1 API specification & server-contract.md.
export const paths = {
  // Auth & user
  login: "/auth/login",
  googleLogin: "/auth/google",
  firebaseLogin: "/auth/firebase",
  changePassword: "/auth/change-password",
  refresh: "/auth/refresh",
  logout: "/auth/logout",
  me: "/me",

  // Public / Student read endpoints
  routes: "/routes",
  routeById: (id: string) => `/routes/${id}`,
  nearestRoute: "/routes/nearest",
  schedules: "/schedules",
  announcements: "/announcements",
  liveBuses: "/buses/live",
  stopEtas: (id: string) => `/stops/${id}/eta`,
  registration: "/me/registration",

  // Admin CRUD & reporting endpoints
  buses: "/admin/buses",
  drivers: "/admin/drivers",
  adminRoutes: "/admin/routes",
  routeStops: (routeId: string) => `/admin/routes/${routeId}/stops`,
  stops: "/admin/stops",
  schedulesAdmin: "/admin/schedules",
  announcementsAdmin: "/admin/announcements",
  students: "/admin/students",
  studentsSummary: "/admin/students/summary",
  reports: "/admin/trips",
  reportsSummary: "/admin/reports/summary",
  settings: "/admin/settings",

  // Driver trip & tracking endpoints
  activeTrip: "/trips/active",
  trips: "/trips/start",
  endTrip: (id: string) => `/trips/${id}/end`,
  tripStatus: (id: string) => `/trips/${id}/status`,
  tripFixes: (id: string) => `/trips/${id}/locations`,
  tripRoster: (id: string) => `/trips/${id}/roster`,
};
