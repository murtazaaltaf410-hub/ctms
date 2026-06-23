import bcrypt from 'bcryptjs';
import { env } from '../config/env.js';

export const hashPassword = (plain) => bcrypt.hash(plain, env.security.bcryptRounds);
export const verifyPassword = (plain, hash) => bcrypt.compare(plain, hash);
