import dotenv from 'dotenv';
dotenv.config();

const required = (key, fallback) => {
  const v = process.env[key] ?? fallback;
  if (v === undefined) throw new Error(`Missing required env var: ${key}`);
  return v;
};

export const env = {
  nodeEnv: process.env.NODE_ENV || 'development',
  port: parseInt(process.env.PORT || '4000', 10),
  clientOrigin: process.env.CLIENT_ORIGIN || 'http://localhost:5173',
  db: {
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '3306', 10),
    user: process.env.DB_USER || 'ctms',
    password: process.env.DB_PASSWORD || 'ctms_password',
    database: process.env.DB_NAME || 'ctms',
    connectionLimit: parseInt(process.env.DB_POOL || '10', 10),
  },
  jwt: {
    accessSecret: required('JWT_ACCESS_SECRET', 'dev_access_secret_change_me'),
    refreshSecret: required('JWT_REFRESH_SECRET', 'dev_refresh_secret_change_me'),
    accessTtl: process.env.JWT_ACCESS_TTL || '15m',
    refreshTtlDays: parseInt(process.env.JWT_REFRESH_TTL_DAYS || '7', 10),
  },
  security: {
    maxFailedAttempts: parseInt(process.env.MAX_FAILED_ATTEMPTS || '5', 10),
    lockMinutes: parseInt(process.env.ACCOUNT_LOCK_MINUTES || '15', 10),
    bcryptRounds: parseInt(process.env.BCRYPT_ROUNDS || '12', 10),
  },
  isProd: (process.env.NODE_ENV || 'development') === 'production',
};
