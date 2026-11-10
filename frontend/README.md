# CTMS web (React + Vite + TS)

    cp .env.example .env      # set VITE_GOOGLE_MAPS_KEY
    npm install
    npm run dev               # http://localhost:5173

Server must allow this origin in CORS (see Phase 1). Endpoint paths: src/api/endpoints.ts.
Assumed response shapes: src/api/types.ts. Verify both against docs/v1/server-contract.md.
