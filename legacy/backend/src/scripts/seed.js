import fs from 'node:fs';
import path from 'node:path';
import mysql from 'mysql2/promise';
import { fileURLToPath } from 'node:url';
import { env } from '../config/env.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sqlFile = path.resolve(__dirname, '../../../database/seed.sql');

const run = async () => {
  const sql = fs.readFileSync(sqlFile, 'utf8');
  const conn = await mysql.createConnection({
    host: env.db.host, port: env.db.port, user: env.db.user,
    password: env.db.password, database: env.db.database, multipleStatements: true,
  });
  await conn.query(sql);
  console.log('[seed] data inserted');
  await conn.end();
};
run().catch((e) => { console.error('[seed] failed:', e.message); process.exit(1); });
