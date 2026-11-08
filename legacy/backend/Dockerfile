# ---- CTMS API ----
FROM node:20-alpine
WORKDIR /app

# Install prod deps first for better layer caching.
COPY package*.json ./
RUN npm ci --omit=dev

COPY src ./src

ENV NODE_ENV=production
EXPOSE 4000

# Drop root privileges (node:alpine ships an unprivileged "node" user).
USER node

CMD ["node", "src/server.js"]
