import { pool } from '../config/db.js';

// Fire-and-forget audit writer. Never throws into the request path.
export const audit = async ({ userId = null, action, entity = null, entityId = null, meta = null, ip = null }) => {
  try {
    await pool.execute(
      `INSERT INTO audit_logs (user_id, action, entity, entity_id, meta, ip_address)
       VALUES (:userId, :action, :entity, :entityId, :meta, :ip)`,
      { userId, action, entity, entityId, meta: meta ? JSON.stringify(meta) : null, ip }
    );
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[audit] failed:', err.message);
  }
};
