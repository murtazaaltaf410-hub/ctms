import { query, pool } from '../config/db.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { emitToAll } from '../sockets/io.js';
import { audit } from '../utils/audit.js';

// GET /api/announcements
export const listAnnouncements = asyncHandler(async (req, res) => {
  const role = req.user.role;
  const audience = role === 'student' ? "('all','students')"
                 : role === 'driver' ? "('all','drivers')" : "('all','students','drivers')";
  const rows = await query(
    `SELECT id, title, body, severity, audience, created_at
       FROM announcements WHERE audience IN ${audience}
      ORDER BY created_at DESC LIMIT 50`);
  res.json({ announcements: rows });
});

// POST /api/announcements (admin) — broadcast in realtime
export const createAnnouncement = asyncHandler(async (req, res) => {
  const { title, body, severity, audience } = req.body;
  const [r] = await pool.execute(
    `INSERT INTO announcements (title, body, severity, audience, created_by)
     VALUES (:title, :body, :sev, :aud, :uid)`,
    { title, body, sev: severity || 'info', aud: audience || 'all', uid: req.user.id });
  const announcement = { id: r.insertId, title, body,
    severity: severity || 'info', audience: audience || 'all', created_at: new Date() };
  emitToAll('announcement:new', announcement);
  await audit({ userId: req.user.id, action: 'create_announcement', entity: 'announcement',
    entityId: r.insertId, ip: req.ip });
  res.status(201).json({ announcement });
});

// GET /api/notifications — current user's inbox
export const listNotifications = asyncHandler(async (req, res) => {
  const rows = await query(
    `SELECT id, type, title, body, is_read, created_at
       FROM notifications WHERE user_id = :uid ORDER BY created_at DESC LIMIT 50`,
    { uid: req.user.id });
  res.json({ notifications: rows });
});

// PATCH /api/notifications/:id/read
export const markRead = asyncHandler(async (req, res) => {
  await pool.execute('UPDATE notifications SET is_read = 1 WHERE id = :id AND user_id = :uid',
    { id: req.params.id, uid: req.user.id });
  res.json({ ok: true });
});
