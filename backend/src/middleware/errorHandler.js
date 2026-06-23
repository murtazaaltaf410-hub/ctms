import { ApiError } from '../utils/ApiError.js';
import { env } from '../config/env.js';

// 404 handler
export const notFound = (req, _res, next) =>
  next(ApiError.notFound(`Route not found: ${req.method} ${req.originalUrl}`));

// Central error handler
// eslint-disable-next-line no-unused-vars
export const errorHandler = (err, _req, res, _next) => {
  const status = err.status || 500;
  if (status >= 500) {
    // eslint-disable-next-line no-console
    console.error('[error]', err);
  }
  res.status(status).json({
    error: err.message || 'Internal server error',
    details: err.details || undefined,
    stack: env.isProd ? undefined : err.stack,
  });
};

// Wraps async controllers so rejected promises hit errorHandler.
export const asyncHandler = (fn) => (req, res, next) =>
  Promise.resolve(fn(req, res, next)).catch(next);
