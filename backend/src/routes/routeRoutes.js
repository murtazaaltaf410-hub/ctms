import { Router } from 'express';
import { authenticate } from '../middleware/auth.js';
import * as route from '../controllers/routeController.js';

const r = Router();
r.get('/', authenticate, route.listRoutes);
r.get('/:id', authenticate, route.getRoute);
export default r;
