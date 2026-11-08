import { body } from 'express-validator';
import { pool, query } from '../config/db.js';
import { hashPassword, verifyPassword } from '../utils/password.js';
import { signAccessToken, generateRefreshToken, hashToken } from '../utils/jwt.js';
import { asyncHandler } from '../middleware/errorHandler.js';
import { ApiError } from '../utils/ApiError.js';
import { audit } from '../utils/audit.js';
import { env } from '../config/env.js';

const REFRESH_COOKIE = 'ctms_rt';

const refreshCookieOpts = () => ({
  httpOnly: true,
  secure: env.isProd,
  sameSite: env.isProd ? 'strict' : 'lax',
  path: '/api/auth',
  maxAge: env.jwt.refreshTtlDays * 24 * 60 * 60 * 1000,
});

const issueSession = async (user, req, res) => {
  const refresh = generateRefreshToken();
  const tokenHash = hashToken(refresh);
  const expiresAt = new Date(Date.now() + env.jwt.refreshTtlDays * 864e5);
  await pool.execute(
    `INSERT INTO sessions (user_id, token_hash, user_agent, ip_address, expires_at)
     VALUES (:userId, :tokenHash, :ua, :ip, :exp)`,
    { userId: user.id, tokenHash, ua: (req.headers['user-agent'] || '').slice(0, 250),
      ip: req.ip, exp: expiresAt }
  );
  res.cookie(REFRESH_COOKIE, refresh, refreshCookieOpts());
  return signAccessToken(user);
};

const publicUser = (u) => ({
  id: u.id, email: u.email, fullName: u.full_name,
  phone: u.phone, role: u.role,
});

// ---- validators ----
export const registerRules = [
  body('email').isEmail().normalizeEmail(),
  body('password').isLength({ min: 8 }).matches(/[A-Z]/).matches(/[0-9]/)
    .withMessage('Password needs 8+ chars, an uppercase letter and a number'),
  body('fullName').trim().isLength({ min: 2, max: 150 }),
  body('enrollmentNo').trim().isLength({ min: 3, max: 40 }),
  body('phone').optional().isLength({ max: 20 }),
];
export const loginRules = [
  body('email').isEmail().normalizeEmail(),
  body('password').isLength({ min: 1 }),
];

// ---- POST /api/auth/register (students only) ----
export const register = asyncHandler(async (req, res) => {
  const { email, password, fullName, phone, enrollmentNo, department, semester } = req.body;
  const existing = await query('SELECT id FROM users WHERE email = :email', { email });
  if (existing.length) throw ApiError.conflict('Email already registered');

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const passwordHash = await hashPassword(password);
    const [userRes] = await conn.execute(
      `INSERT INTO users (email, password_hash, full_name, phone, role)
       VALUES (:email, :hash, :name, :phone, 'student')`,
      { email, hash: passwordHash, name: fullName, phone: phone || null }
    );
    const userId = userRes.insertId;
    await conn.execute(
      `INSERT INTO students (user_id, enrollment_no, department, semester)
       VALUES (:uid, :enr, :dept, :sem)`,
      { uid: userId, enr: enrollmentNo, dept: department || null, sem: semester || null }
    );
    await conn.commit();
    await audit({ userId, action: 'register', entity: 'user', entityId: userId, ip: req.ip });
    res.status(201).json({ message: 'Registered. You can now log in.' });
  } catch (e) {
    await conn.rollback();
    if (e.code === 'ER_DUP_ENTRY') throw ApiError.conflict('Enrollment number already in use');
    throw e;
  } finally {
    conn.release();
  }
});

// ---- POST /api/auth/login ----
export const login = asyncHandler(async (req, res) => {
  const { email, password } = req.body;
  const rows = await query('SELECT * FROM users WHERE email = :email', { email });
  const user = rows[0];

  // Uniform failure to avoid user enumeration.
  if (!user) {
    await audit({ action: 'login_failed', meta: { email }, ip: req.ip });
    throw ApiError.unauthorized('Invalid credentials');
  }
  if (user.locked_until && new Date(user.locked_until) > new Date()) {
    throw ApiError.locked('Account temporarily locked. Try again later.');
  }
  if (!user.is_active) throw ApiError.forbidden('Account disabled');

  const ok = await verifyPassword(password, user.password_hash);
  if (!ok) {
    const attempts = user.failed_attempts + 1;
    const lock = attempts >= env.security.maxFailedAttempts;
    await pool.execute(
      `UPDATE users SET failed_attempts = :a,
         locked_until = :lock WHERE id = :id`,
      { a: attempts,
        lock: lock ? new Date(Date.now() + env.security.lockMinutes * 60000) : null,
        id: user.id }
    );
    await audit({ userId: user.id, action: 'login_failed', ip: req.ip });
    throw ApiError.unauthorized('Invalid credentials');
  }

  await pool.execute(
    `UPDATE users SET failed_attempts = 0, locked_until = NULL,
       last_login_at = NOW() WHERE id = :id`, { id: user.id }
  );
  const accessToken = await issueSession(user, req, res);
  await audit({ userId: user.id, action: 'login', ip: req.ip });
  res.json({ accessToken, user: publicUser(user) });
});

// ---- POST /api/auth/refresh ----
export const refresh = asyncHandler(async (req, res) => {
  const token = req.cookies?.[REFRESH_COOKIE];
  if (!token) throw ApiError.unauthorized('No refresh token');
  const tokenHash = hashToken(token);
  const rows = await query(
    `SELECT s.*, u.role, u.full_name, u.email, u.phone, u.is_active
       FROM sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = :h LIMIT 1`, { h: tokenHash }
  );
  const session = rows[0];
  if (!session || session.revoked_at || new Date(session.expires_at) < new Date() || !session.is_active) {
    throw ApiError.unauthorized('Session expired, please log in again');
  }
  // Rotate: revoke old, issue new.
  await pool.execute('UPDATE sessions SET revoked_at = NOW() WHERE id = :id', { id: session.id });
  const user = { id: session.user_id, role: session.role, full_name: session.full_name,
                 email: session.email, phone: session.phone };
  const accessToken = await issueSession(user, req, res);
  res.json({ accessToken, user: publicUser(user) });
});

// ---- POST /api/auth/logout ----
export const logout = asyncHandler(async (req, res) => {
  const token = req.cookies?.[REFRESH_COOKIE];
  if (token) {
    await pool.execute('UPDATE sessions SET revoked_at = NOW() WHERE token_hash = :h',
      { h: hashToken(token) });
  }
  res.clearCookie(REFRESH_COOKIE, { path: '/api/auth' });
  res.json({ message: 'Logged out' });
});

// ---- GET /api/auth/me ----
export const me = asyncHandler(async (req, res) => {
  const rows = await query('SELECT * FROM users WHERE id = :id', { id: req.user.id });
  if (!rows[0]) throw ApiError.notFound('User not found');
  res.json({ user: publicUser(rows[0]) });
});

// ---- POST /api/auth/password-reset (demo flow: returns a reset token) ----
// In production this token would be emailed, never returned in the response.
export const passwordReset = asyncHandler(async (req, res) => {
  const { email } = req.body;
  const rows = await query('SELECT id FROM users WHERE email = :email', { email });
  // Always return 200 to avoid leaking which emails exist.
  if (rows[0]) {
    await audit({ userId: rows[0].id, action: 'password_reset_requested', ip: req.ip });
  }
  res.json({ message: 'If that account exists, a reset link has been sent.' });
});
