import { Router } from 'express';
import { body } from 'express-validator';
import { authLimiter } from '../middleware/rateLimit.js';
import { validate } from '../middleware/validate.js';
import { authenticate } from '../middleware/auth.js';
import * as auth from '../controllers/authController.js';

const r = Router();
r.post('/register', authLimiter, auth.registerRules, validate, auth.register);
r.post('/login', authLimiter, auth.loginRules, validate, auth.login);
r.post('/refresh', auth.refresh);
r.post('/logout', auth.logout);
r.get('/me', authenticate, auth.me);
r.post('/password-reset', authLimiter, body('email').isEmail(), validate, auth.passwordReset);
export default r;
