import { Server } from 'socket.io';
import { setIO } from './io.js';
import { verifySocketToken } from '../middleware/auth.js';
import { env } from '../config/env.js';

export const initSockets = (httpServer) => {
  const io = new Server(httpServer, {
    cors: { origin: env.clientOrigin, credentials: true },
  });
  setIO(io);

  // Handshake auth: token passed via socket.handshake.auth.token
  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token) return next(new Error('Auth token required'));
    try {
      const payload = verifySocketToken(token);
      socket.user = { id: payload.sub, role: payload.role, name: payload.name };
      next();
    } catch {
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', (socket) => {
    // Students/admins join the global tracking room.
    socket.join('tracking');
    if (socket.user.role === 'admin') socket.join('admins');

    // Subscribe to a specific bus channel for focused updates.
    socket.on('bus:subscribe', (busId) => {
      if (busId) socket.join(`bus:${busId}`);
    });
    socket.on('bus:unsubscribe', (busId) => {
      if (busId) socket.leave(`bus:${busId}`);
    });

    socket.on('disconnect', () => { /* cleanup handled by socket.io */ });
  });

  return io;
};
