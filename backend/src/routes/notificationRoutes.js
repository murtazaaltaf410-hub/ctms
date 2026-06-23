import { Router } from 'express';
import { authenticate } from '../middleware/auth.js';
import * as a from '../controllers/announcementController.js';

const r = Router();
r.get('/', authenticate, a.listNotifications);
r.patch('/:id/read', authenticate, a.markRead);
export default r;
