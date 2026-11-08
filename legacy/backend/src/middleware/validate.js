import { validationResult } from 'express-validator';
import { ApiError } from '../utils/ApiError.js';

// Run after an express-validator chain; collapses errors into ApiError 400.
export const validate = (req, _res, next) => {
  const result = validationResult(req);
  if (!result.isEmpty()) {
    return next(ApiError.badRequest('Validation failed', result.array().map(e => ({
      field: e.path, message: e.msg,
    }))));
  }
  next();
};
