import mysql from 'mysql2/promise';
import { env } from './env.js';

// Single shared connection pool. mysql2 uses prepared statements via
// pool.execute(), which parameterises queries and prevents SQL injection.
export const pool = mysql.createPool({
  host: env.db.host,
  port: env.db.port,
  user: env.db.user,
  password: env.db.password,
  database: env.db.database,
  waitForConnections: true,
  connectionLimit: env.db.connectionLimit,
  queueLimit: 0,
  namedPlaceholders: true,
  timezone: 'Z',
  charset: 'utf8mb4_unicode_ci',
});

// Helper: run a parameterised query, return rows.
export const query = async (sql, params = {}) => {
  const [rows] = await pool.execute(sql, params);
  return rows;
};

export const ping = async () => {
  const conn = await pool.getConnection();
  try { await conn.ping(); } finally { conn.release(); }
};
