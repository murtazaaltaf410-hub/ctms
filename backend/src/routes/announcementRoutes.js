import { Router } from 'express';
import { body } from 'express-validator';
import { authenticate } from '../middleware/auth.js';
import { authorize } from '../middleware/rbac.js';
import { validate } from '../middleware/validate.js';
import * as a from '../controllers/announcementController.js';

const r = Router();
r.get('/', authenticate, a.listAnnouncements);
r.post('/', authenticate, authorize('admin'),
  [body('title').trim().notEmpty(), body('body').trim().notEmpty()], validate, a.createAnnouncement);
export default r;
