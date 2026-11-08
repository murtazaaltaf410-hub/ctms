import { useEffect, useRef } from 'react';
import { io } from 'socket.io-client';
import { getAccessToken } from '../api/client.js';

// Establishes an authenticated socket connection. Re-connects when the
// token changes. Returns a ref to the live socket.
export const useSocket = (enabled) => {
  const socketRef = useRef(null);
  useEffect(() => {
    if (!enabled) return;
    const socket = io('/', {
      auth: { token: getAccessToken() },
      transports: ['websocket', 'polling'],
    });
    socketRef.current = socket;
    return () => { socket.disconnect(); socketRef.current = null; };
  }, [enabled]);
  return socketRef;
};
