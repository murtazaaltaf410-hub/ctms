import { Router } from 'express';
import { body } from 'express-validator';
import { authenticate } from '../middleware/auth.js';
import { authorize } from '../middleware/rbac.js';
import { validate } from '../middleware/validate.js';
import * as admin from '../controllers/adminController.js';

const r = Router();
r.use(authenticate, authorize('admin'));
r.get('/overview', admin.overview);
r.get('/analytics', admin.analytics);
r.get('/users', admin.listUsers);
r.post('/drivers',
  [body('email').isEmail(), body('password').isLength({ min: 8 }),
   body('fullName').notEmpty(), body('licenseNo').notEmpty()], validate, admin.createDriver);
r.patch('/users/:id/active', admin.toggleUser);
r.get('/audit', admin.auditLogs);
export default r;
