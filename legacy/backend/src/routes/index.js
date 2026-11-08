import { Router } from 'express';
import authRoutes from './authRoutes.js';
import busRoutes from './busRoutes.js';
import routeRoutes from './routeRoutes.js';
import trackingRoutes from './trackingRoutes.js';
import announcementRoutes from './announcementRoutes.js';
import notificationRoutes from './notificationRoutes.js';
import adminRoutes from './adminRoutes.js';

const api = Router();
api.use('/auth', authRoutes);
api.use('/buses', busRoutes);
api.use('/routes', routeRoutes);
api.use('/tracking', trackingRoutes);
api.use('/announcements', announcementRoutes);
api.use('/notifications', notificationRoutes);
api.use('/admin', adminRoutes);
export default api;
