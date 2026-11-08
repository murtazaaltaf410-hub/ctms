import { query, pool } from '../config/db.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { ApiError } from '../utils/ApiError.js';
import { hashPassword } from '../utils/password.js';
import { audit } from '../utils/audit.js';

// GET /api/admin/overview — dashboard KPIs
export const overview = asyncHandler(async (_req, res) => {
  const [[students]] = [await query("SELECT COUNT(*) c FROM users WHERE role='student'")];
  const [[drivers]] = [await query("SELECT COUNT(*) c FROM users WHERE role='driver'")];
  const [[buses]] = [await query('SELECT COUNT(*) c FROM buses WHERE is_active=1')];
  const [[routes]] = [await query('SELECT COUNT(*) c FROM routes WHERE is_active=1')];
  const statusBreakdown = await query(
    'SELECT status, COUNT(*) c FROM buses WHERE is_active=1 GROUP BY status');
  const recentLogins = await query(
    `SELECT u.full_name, u.role, a.created_at
       FROM audit_logs a JOIN users u ON u.id=a.user_id
      WHERE a.action='login' ORDER BY a.created_at DESC LIMIT 8`);
  res.json({
    kpis: { students: students.c, drivers: drivers.c, buses: buses.c, routes: routes.c },
    statusBreakdown, recentLogins,
  });
});

// GET /api/admin/users?role=
export const listUsers = asyncHandler(async (req, res) => {
  const role = req.query.role;
  const rows = role
    ? await query(`SELECT id, email, full_name, role, is_active, last_login_at, created_at
                     FROM users WHERE role = :role ORDER BY created_at DESC`, { role })
    : await query(`SELECT id, email, full_name, role, is_active, last_login_at, created_at
                     FROM users ORDER BY created_at DESC`);
  res.json({ users: rows });
});

// POST /api/admin/drivers — create a driver + user in one txn
export const createDriver = asyncHandler(async (req, res) => {
  const { email, password, fullName, phone, licenseNo, assignedBusId } = req.body;
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const hash = await hashPassword(password);
    const [u] = await conn.execute(
      `INSERT INTO users (email, password_hash, full_name, phone, role)
       VALUES (:email,:hash,:name,:phone,'driver')`,
      { email, hash, name: fullName, phone: phone || null });
    await conn.execute(
      `INSERT INTO drivers (user_id, license_no, assigned_bus_id)
       VALUES (:uid,:lic,:bus)`,
      { uid: u.insertId, lic: licenseNo, bus: assignedBusId || null });
    await conn.commit();
    await audit({ userId: req.user.id, action: 'create_driver', entity: 'user',
      entityId: u.insertId, ip: req.ip });
    res.status(201).json({ id: u.insertId });
  } catch (e) {
    await conn.rollback();
    if (e.code === 'ER_DUP_ENTRY') throw ApiError.conflict('Email, license or bus already in use');
    throw e;
  } finally { conn.release(); }
});

// PATCH /api/admin/users/:id/active
export const toggleUser = asyncHandler(async (req, res) => {
  await pool.execute('UPDATE users SET is_active = :a WHERE id = :id',
    { a: req.body.isActive ? 1 : 0, id: req.params.id });
  await audit({ userId: req.user.id, action: 'toggle_user', entity: 'user',
    entityId: req.params.id, meta: { isActive: !!req.body.isActive }, ip: req.ip });
  res.json({ ok: true });
});

// GET /api/admin/audit?limit=
export const auditLogs = asyncHandler(async (req, res) => {
  const limit = Math.min(parseInt(req.query.limit || '50', 10), 200);
  const rows = await query(
    `SELECT a.id, a.action, a.entity, a.entity_id, a.ip_address, a.created_at,
            u.full_name, u.role
       FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id
      ORDER BY a.created_at DESC LIMIT ${limit}`);
  res.json({ logs: rows });
});

// GET /api/admin/analytics — simple time-series for charts
export const analytics = asyncHandler(async (_req, res) => {
  const logins7d = await query(`
    SELECT DATE(created_at) d, COUNT(*) c
      FROM audit_logs WHERE action='login' AND created_at >= NOW() - INTERVAL 7 DAY
     GROUP BY DATE(created_at) ORDER BY d`);
  const occupancy = await query(
    'SELECT occupancy, COUNT(*) c FROM buses WHERE is_active=1 GROUP BY occupancy');
  res.json({ logins7d, occupancy });
});
