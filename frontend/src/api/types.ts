// Matched to CTMS V1 API specification & server-contract.md.
export type Role = "student" | "driver" | "admin";

export interface User {
  id: string;
  name: string;
  role: Role;
  email?: string | null;
  phone?: string | null;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
}

export interface LoginResponse extends TokenPair {
  user: User;
  must_change_password?: boolean;
}

export interface Page<T> {
  items: T[];
  next_cursor: string | null;
}

export interface Stop {
  id: string;
  name: string;
  lat: number;
  lng: number;
  route_id?: string;
  sequence?: number;
}

export interface RouteDto {
  id: string;
  name: string;
  active?: boolean;
  stop_count?: number;
  stops?: Stop[];
  polyline?: string | { lat: number; lng: number }[];
}

export interface BusFix {
  bus_id: string;
  trip_id?: string;
  label?: string;
  route_id?: string;
  lat: number;
  lng: number;
  speed?: number;
  speed_mps?: number;
  heading?: number;
  status?: "on_time" | "delayed" | "breakdown" | string;
  note?: string | null;
  state?: "live" | "stale" | "offline" | string;
  last_fix_at?: string;
  recorded_at?: string;
  updated_at: string;
}


export interface BusDto {
  id: string;
  label: string;
  plate: string;
  capacity?: number | null;
  active: boolean;
}

export interface DriverDto {
  id: string;
  name: string;
  userid?: string | null;
  phone?: string | null;
  email?: string | null;
  bus_id?: string | null;
  active: boolean;
  must_change_password?: boolean;
  locked?: boolean;
  temporary_password?: string;
}

export interface TripReportDto {
  id: string;
  bus_label?: string;
  driver_name?: string;
  route_name?: string;
  type?: "scheduled" | "ad_hoc";
  direction?: "to_campus" | "from_campus";
  status?: string;
  started_at: string;
  moved_at?: string | null;
  arrived_at?: string | null;
  ended_at?: string | null;
  closed_by?: "driver" | "auto" | "arrival" | null;
  distance_m?: number;
  avg_speed_mps?: number;
}
