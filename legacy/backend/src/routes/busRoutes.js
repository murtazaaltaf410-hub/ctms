import { Router } from 'express';
import { body } from 'express-validator';
import { authenticate } from '../middleware/auth.js';
import { authorize } from '../middleware/rbac.js';
import { validate } from '../middleware/validate.js';
import * as bus from '../controllers/busController.js';

const r = Router();
r.get('/', authenticate, bus.listBuses);
r.get('/:id', authenticate, bus.getBus);
r.post('/', authenticate, authorize('admin'),
  [body('regNo').trim().notEmpty(), body('label').trim().notEmpty()], validate, bus.createBus);
r.patch('/:id', authenticate, authorize('admin'), bus.updateBus);
r.delete('/:id', authenticate, authorize('admin'), bus.deleteBus);
export default r;
