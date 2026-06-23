import { ApiError } from '../utils/ApiError.js';

// Role-based authorization. Usage: authorize('admin'), authorize('admin','driver')
export const authorize = (...roles) => (req, _res, next) => {
  if (!req.user) return next(ApiError.unauthorized());
  if (!roles.includes(req.user.role)) return next(ApiError.forbidden('Insufficient role'));
  next();
};
