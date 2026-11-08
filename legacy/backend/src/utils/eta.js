// Haversine distance (km) between two lat/lng points.
export const haversineKm = (lat1, lng1, lat2, lng2) => {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
};

// ETA in minutes given distance and current speed (km/h). Falls back to a
// sane average speed when the bus is stationary or speed is unknown.
export const etaMinutes = (distanceKm, speedKmh) => {
  const speed = speedKmh && speedKmh > 5 ? speedKmh : 25; // assumed avg
  return Math.max(1, Math.round((distanceKm / speed) * 60));
};
