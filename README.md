# Campus Transport Management System (CTMS)

Real-time university bus tracking for the **University of Kashmir, North Campus** transport department.
Students track buses live on a map, drivers stream GPS + status, and admins manage the fleet — all over a hardened Node/Express + Socket.IO backend, a MySQL 8 datastore, and a React 19 SPA.

---

## Stack

| Layer     | Tech |
|-----------|------|
| Frontend  | React 19, Vite, Tailwind CSS, Framer Motion, React Router, Axios, Socket.IO client, Leaflet / OpenStreetMap, React Hook Form, Zod |
| Backend   | Node.js, Express, Socket.IO, JWT (access + rotating refresh), Bcrypt, Helmet, express-validator, express-rate-limit, CORS, Multer |
| Database  | MySQL 8 (InnoDB, normalized, FKs + indexes) |
| Delivery  | Docker, Docker Compose, Nginx reverse proxy (SPA + API + WebSocket) |

---

## Quick start (Docker — recommended)

```bash
cp .env.example .env          # then edit the JWT secrets for anything non-local
docker compose up --build
```

- App:        http://localhost:8080
- API docs:   http://localhost:8080/api/docs  (Swagger UI)
- Health:     http://localhost:8080/api/../health  → `GET /health` on the API

The MySQL container loads `database/schema.sql` then `database/seed.sql` automatically on **first** boot
(an empty data volume). To re-seed from scratch: `docker compose down -v && docker compose up --build`.

### Seeded login credentials

| Role    | Email                          | Password      |
|---------|--------------------------------|---------------|
| Admin   | `admin@ctms.uok.edu.in`        | `Admin@123`   |
| Driver  | `driver1@ctms.uok.edu.in`      | `Driver@123`  |
| Driver  | `driver2@ctms.uok.edu.in`      | `Driver@123`  |
| Student | `student1@ctms.uok.edu.in`     | `Student@123` |
| Student | `student2@ctms.uok.edu.in`     | `Student@123` |

> These are demo credentials. **Rotate the admin password and JWT secrets before any real deployment.**

---

## Local development (no Docker)

You need a running MySQL 8 instance.

```bash
# 1. Database
mysql -u root -p < database/schema.sql
mysql -u root -p < database/seed.sql

# 2. Backend
cd backend
cp .env.example .env          # point DB_* at your MySQL
npm install
npm run dev                   # http://localhost:4000  (docs at /api/docs)

# 3. Frontend (second terminal)
cd frontend
npm install
npm run dev                   # http://localhost:5173  (proxies /api + /socket.io to :4000)
```

`npm run migrate` / `npm run seed` in `backend/` run the SQL via Node if you prefer that over the `mysql` CLI.

---

## Architecture

```
Browser ──HTTP/WS──> Nginx (:80/8080)
                       ├── /            → React SPA (static build)
                       ├── /api/*       → proxy → Node API (:4000)
                       └── /socket.io/* → proxy (ws upgrade) → Node API (:4000)
                                                  │
                                                  └──> MySQL 8 (:3306)
```

- **Same-origin** everywhere: the SPA calls `/api`, so there's no CORS in production and the
  refresh token can live in an `httpOnly` cookie.
- The **access token is held in memory** (XSS-safer); a 401 triggers one silent `/auth/refresh`
  then replays the request (see `frontend/src/api/client.js`).
- Controllers emit realtime events through a tiny `sockets/io.js` registry, avoiding circular imports.

---

## Security

- JWT access tokens (15 min) + **rotating** refresh tokens; only the SHA-256 of each refresh token
  is stored in `sessions`, so a DB leak yields no usable tokens.
- Bcrypt password hashing (cost 12), **account lockout** after 5 failed attempts.
- Login failures are uniform to prevent **user enumeration**; password-reset never reveals account existence.
- All queries are **parameterized** (mysql2 prepared statements / named placeholders) → SQL-injection safe.
- Helmet security headers, per-route **rate limiting**, role-based authorization on every protected route,
  and an **audit log** of security-relevant actions.
- Secrets via env vars; secure/sameSite cookies in production.

---

## API

REST under `/api`, documented with **Swagger/OpenAPI** at `/api/docs` (raw spec at `/api/docs.json`).

| Group          | Routes |
|----------------|--------|
| Auth           | `POST /auth/register · /auth/login · /auth/refresh · /auth/logout · /auth/password-reset`, `GET /auth/me` |
| Buses          | `GET /buses · /buses/:id`, `POST/PATCH/DELETE /buses` (admin) |
| Routes         | `GET /routes · /routes/:id` |
| Tracking       | `POST /tracking/location · /tracking/status` (driver), `GET /tracking/eta` |
| Announcements  | `GET /announcements`, `POST/DELETE` (admin) |
| Notifications  | `GET /notifications`, mark read |
| Admin          | `GET /admin/overview · /analytics · /users · /audit`, `POST /admin/drivers`, `PATCH /admin/users/:id/active` |

### Realtime (Socket.IO)
Handshake requires the access token (`socket.handshake.auth.token`).
Events: `bus:location`, `bus:status`, `bus:subscribe`/`bus:unsubscribe`, announcement broadcasts.

---

## Project structure

```
ctms/
├── docker-compose.yml
├── nginx/nginx.conf
├── database/{schema.sql, seed.sql}        # 14 normalized tables + UoK-anchored seed
├── backend/
│   ├── Dockerfile
│   └── src/{config, controllers, routes, middleware, sockets, utils, docs, scripts}
└── frontend/
    ├── Dockerfile
    └── src/{api, context, hooks, components, pages}
```

---

## Tests

```bash
cd backend && npm test     # node:test runner — utils (ETA/haversine) + API smoke tests
```

API/integration tests assume a reachable test database; unit tests (ETA math, token hashing) run standalone.

---

## Status — what's done vs. what's scaffolded

**Complete and runnable:** full DB schema + seed, auth (register/login/refresh/logout/lockout/audit),
RBAC, security middleware, bus/route/tracking/announcement/admin controllers, Socket.IO realtime,
Swagger, Docker Compose + Nginx, and the Student / Driver / Admin dashboards with the live Leaflet map.

**Intentionally lean (extend as needed):**
- Charts are dependency-free CSS bars; swap in Recharts for richer analytics.
- Password reset returns success without emailing a token (no mail provider wired) — the secure
  no-enumeration flow is in place; connect an SMTP/transactional provider to finish it.
- Notification fan-out covers core events; add per-stop arrival triggers as your routes firm up.

---

## Troubleshooting

- **API exits with `[db] connection failed`** — MySQL isn't ready/credentials mismatch. Under Compose the
  API waits for the DB healthcheck; locally, confirm `DB_*` in `backend/.env`.
- **Seed didn't load** — MySQL only runs init scripts on a fresh volume. Use `docker compose down -v`.
- **WebSocket won't connect in prod** — ensure the `/socket.io/` Nginx block (with `Upgrade` headers) is present.
