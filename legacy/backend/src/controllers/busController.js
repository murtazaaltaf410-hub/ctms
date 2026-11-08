import { query, pool } from '../config/db.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { ApiError } from '../utils/ApiError.js';

// GET /api/buses  — list buses with route + latest location
export const listBuses = asyncHandler(async (_req, res) => {
  const buses = await query(`
    SELECT b.id, b.reg_no, b.label, b.capacity, b.status, b.occupancy,
           b.route_id, r.code AS route_code, r.name AS route_name,
           loc.latitude, loc.longitude, loc.speed_kmh, loc.heading, loc.recorded_at
      FROM buses b
      LEFT JOIN routes r ON r.id = b.route_id
      LEFT JOIN bus_locations loc ON loc.id = (
          SELECT id FROM bus_locations WHERE bus_id = b.id
          ORDER BY recorded_at DESC, id DESC LIMIT 1)
     WHERE b.is_active = 1
     ORDER BY b.id`);
  res.json({ buses });
});

// GET /api/buses/:id — single bus detail incl. route polyline + stops
export const getBus = asyncHandler(async (req, res) => {
  const id = req.params.id;
  const rows = await query(`
    SELECT b.*, r.code AS route_code, r.name AS route_name, r.path AS route_path
      FROM buses b LEFT JOIN routes r ON r.id = b.route_id
     WHERE b.id = :id`, { id });
  if (!rows[0]) throw ApiError.notFound('Bus not found');
  const bus = rows[0];
  const stops = bus.route_id ? await query(`
    SELECT s.id, s.name, s.latitude, s.longitude, rs.stop_order, rs.eta_offset_min
      FROM route_stops rs JOIN stops s ON s.id = rs.stop_id
     WHERE rs.route_id = :rid ORDER BY rs.stop_order`, { rid: bus.route_id }) : [];
  const loc = await query(`
    SELECT latitude, longitude, speed_kmh, heading, recorded_at
      FROM bus_locations WHERE bus_id = :id ORDER BY recorded_at DESC, id DESC LIMIT 1`,
    { id });
  res.json({ bus: { ...bus, route_path: bus.route_path || null }, stops, location: loc[0] || null });
});

// POST /api/buses (admin)
export const createBus = asyncHandler(async (req, res) => {
  const { regNo, label, capacity, routeId } = req.body;
  try {
    const [r] = await pool.execute(
      `INSERT INTO buses (reg_no, label, capacity, route_id)
       VALUES (:reg, :label, :cap, :route)`,
      { reg: regNo, label, cap: capacity || 40, route: routeId || null });
    res.status(201).json({ id: r.insertId });
  } catch (e) {
    if (e.code === 'ER_DUP_ENTRY') throw ApiError.conflict('Registration number exists');
    throw e;
  }
});

// PATCH /api/buses/:id (admin)
export const updateBus = asyncHandler(async (req, res) => {
  const { label, capacity, routeId, isActive } = req.body;
  await pool.execute(
    `UPDATE buses SET
       label = COALESCE(:label, label),
       capacity = COALESCE(:cap, capacity),
       route_id = COALESCE(:route, route_id),
       is_active = COALESCE(:active, is_active)
     WHERE id = :id`,
    { label: label ?? null, cap: capacity ?? null, route: routeId ?? null,
      active: isActive ?? null, id: req.params.id });
  res.json({ message: 'Bus updated' });
});

// DELETE /api/buses/:id (admin) — soft delete
export const deleteBus = asyncHandler(async (req, res) => {
  await pool.execute('UPDATE buses SET is_active = 0 WHERE id = :id', { id: req.params.id });
  res.json({ message: 'Bus deactivated' });
});
