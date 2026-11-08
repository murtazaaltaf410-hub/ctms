import { Router } from 'express';
import { body } from 'express-validator';
import { authenticate } from '../middleware/auth.js';
import { authorize } from '../middleware/rbac.js';
import { validate } from '../middleware/validate.js';
import * as t from '../controllers/trackingController.js';

const r = Router();
r.post('/location', authenticate, authorize('driver'),
  [body('latitude').isFloat({ min: -90, max: 90 }),
   body('longitude').isFloat({ min: -180, max: 180 })], validate, t.pushLocation);
r.post('/status', authenticate, authorize('driver'),
  [body('status').optional().isIn(['idle','on_time','delayed','breakdown','completed']),
   body('occupancy').optional().isIn(['available','moderate','full'])], validate, t.updateStatus);
r.get('/eta', authenticate, t.getEta);
export default r;
