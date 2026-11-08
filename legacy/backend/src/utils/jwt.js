import jwt from 'jsonwebtoken';
import crypto from 'node:crypto';
import { env } from '../config/env.js';

export const signAccessToken = (user) =>
  jwt.sign(
    { sub: user.id, role: user.role, name: user.full_name },
    env.jwt.accessSecret,
    { expiresIn: env.jwt.accessTtl }
  );

export const verifyAccessToken = (token) =>
  jwt.verify(token, env.jwt.accessSecret);

// Refresh tokens are opaque random strings. We store only their sha256
// in the sessions table, so a DB leak never exposes usable tokens.
export const generateRefreshToken = () => crypto.randomBytes(48).toString('hex');
export const hashToken = (token) =>
  crypto.createHash('sha256').update(token).digest('hex');
