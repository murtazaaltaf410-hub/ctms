import { query } from '../config/db.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { ApiError } from '../utils/ApiError.js';

export const listRoutes = asyncHandler(async (_req, res) => {
  const routes = await query(
    'SELECT id, code, name, description, path, distance_km, is_active FROM routes WHERE is_active = 1 ORDER BY code');
  res.json({ routes });
});

export const getRoute = asyncHandler(async (req, res) => {
  const rows = await query('SELECT * FROM routes WHERE id = :id', { id: req.params.id });
  if (!rows[0]) throw ApiError.notFound('Route not found');
  const stops = await query(`
    SELECT s.id, s.name, s.latitude, s.longitude, rs.stop_order, rs.eta_offset_min
      FROM route_stops rs JOIN stops s ON s.id = rs.stop_id
     WHERE rs.route_id = :id ORDER BY rs.stop_order`, { id: req.params.id });
  res.json({ route: rows[0], stops });
});
