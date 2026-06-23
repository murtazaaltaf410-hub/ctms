import { query, pool } from '../config/db.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { ApiError } from '../utils/ApiError.js';
import { haversineKm, etaMinutes } from '../utils/eta.js';
import { emitToAll, emitToRoom } from '../sockets/io.js';
import { audit } from '../utils/audit.js';

// Resolve the bus assigned to the authenticated driver.
const driverBus = async (userId) => {
  const rows = await query(
    `SELECT d.assigned_bus_id AS bus_id, b.route_id
       FROM drivers d JOIN buses b ON b.id = d.assigned_bus_id
      WHERE d.user_id = :uid`, { uid: userId });
  return rows[0] || null;
};

// POST /api/tracking/location  (driver) — push a GPS fix
export const pushLocation = asyncHandler(async (req, res) => {
  const { latitude, longitude, speed, heading } = req.body;
  const assign = await driverBus(req.user.id);
  if (!assign) throw ApiError.forbidden('No bus assigned to this driver');

  await pool.execute(
    `INSERT INTO bus_locations (bus_id, latitude, longitude, speed_kmh, heading)
     VALUES (:bus, :lat, :lng, :spd, :hdg)`,
    { bus: assign.bus_id, lat: latitude, lng: longitude,
      spd: speed ?? null, hdg: heading ?? null });

  const payload = {
    busId: assign.bus_id, latitude, longitude,
    speed: speed ?? null, heading: heading ?? null, ts: Date.now(),
  };
  // Broadcast to everyone watching this bus + the global tracking room.
  emitToRoom(`bus:${assign.bus_id}`, 'bus:location', payload);
  emitToRoom('tracking', 'bus:location', payload);
  res.json({ ok: true });
});

// POST /api/tracking/status (driver) — set bus status / occupancy / journey
export const updateStatus = asyncHandler(async (req, res) => {
  const { status, occupancy } = req.body;
  const assign = await driverBus(req.user.id);
  if (!assign) throw ApiError.forbidden('No bus assigned to this driver');

  await pool.execute(
    `UPDATE buses SET status = COALESCE(:status, status),
       occupancy = COALESCE(:occ, occupancy) WHERE id = :id`,
    { status: status ?? null, occ: occupancy ?? null, id: assign.bus_id });

  const payload = { busId: assign.bus_id, status, occupancy, ts: Date.now() };
  emitToAll('bus:status', payload);
  await audit({ userId: req.user.id, action: 'bus_status_update', entity: 'bus',
    entityId: assign.bus_id, meta: { status, occupancy }, ip: req.ip });
  res.json({ ok: true });
});

// GET /api/tracking/eta?busId=&lat=&lng=  — ETA from bus to a point/stop
export const getEta = asyncHandler(async (req, res) => {
  const { busId, lat, lng } = req.query;
  if (!busId || !lat || !lng) throw ApiError.badRequest('busId, lat, lng required');
  const rows = await query(
    `SELECT latitude, longitude, speed_kmh FROM bus_locations
      WHERE bus_id = :bus ORDER BY recorded_at DESC, id DESC LIMIT 1`, { bus: busId });
  if (!rows[0]) throw ApiError.notFound('No location for this bus yet');
  const { latitude, longitude, speed_kmh } = rows[0];
  const distanceKm = haversineKm(+latitude, +longitude, +lat, +lng);
  res.json({
    busId: Number(busId),
    distanceKm: Number(distanceKm.toFixed(2)),
    etaMinutes: etaMinutes(distanceKm, Number(speed_kmh)),
    from: { latitude: +latitude, longitude: +longitude },
  });
});
