import http from 'node:http';
import { createApp } from './app.js';
import { initSockets } from './sockets/index.js';
import { ping } from './config/db.js';
import { env } from './config/env.js';

const start = async () => {
  try {
    await ping();
    // eslint-disable-next-line no-console
    console.log('[db] connection pool ready');
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error('[db] connection failed:', e.message);
    process.exit(1);
  }

  const app = createApp();
  const server = http.createServer(app);
  initSockets(server);

  server.listen(env.port, () => {
    // eslint-disable-next-line no-console
    console.log(`[ctms] API + sockets on :${env.port} (${env.nodeEnv})`);
    console.log(`[ctms] Swagger docs at http://localhost:${env.port}/api/docs`);
  });

  const shutdown = (sig) => {
    console.log(`\n[ctms] ${sig} received, shutting down...`);
    server.close(() => process.exit(0));
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
};

start();
