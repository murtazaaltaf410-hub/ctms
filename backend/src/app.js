import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import swaggerUi from 'swagger-ui-express';
import { env } from './config/env.js';
import { apiLimiter } from './middleware/rateLimit.js';
import { notFound, errorHandler } from './middleware/errorHandler.js';
import { openApiSpec } from './docs/swagger.js';
import api from './routes/index.js';

export const createApp = () => {
  const app = express();
  app.set('trust proxy', 1); // behind nginx

  // Security headers (Helmet) + CSP relaxed enough for swagger UI.
  app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
  app.use(cors({ origin: env.clientOrigin, credentials: true }));
  app.use(express.json({ limit: '1mb' }));
  app.use(express.urlencoded({ extended: true }));
  app.use(cookieParser());

  app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }));
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(openApiSpec));
  app.get('/api/docs.json', (_req, res) => res.json(openApiSpec));

  app.use('/api', apiLimiter, api);

  app.use(notFound);
  app.use(errorHandler);
  return app;
};
