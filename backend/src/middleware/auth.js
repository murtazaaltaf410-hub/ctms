import { verifyAccessToken } from '../utils/jwt.js';
import { ApiError } from '../utils/ApiError.js';

// Verifies the Bearer access token and attaches req.user.
export const authenticate = (req, _res, next) => {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return next(ApiError.unauthorized('Missing access token'));
  try {
    const payload = verifyAccessToken(token);
    req.user = { id: payload.sub, role: payload.role, name: payload.name };
    next();
  } catch {
    next(ApiError.unauthorized('Invalid or expired token'));
  }
};

// Same as authenticate but used for socket handshakes (returns payload).
export const verifySocketToken = (token) => verifyAccessToken(token);
