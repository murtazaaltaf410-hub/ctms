// Holds the Socket.IO server instance so non-socket modules (controllers)
// can emit realtime events without a circular import.
let _io = null;
export const setIO = (io) => { _io = io; };
export const getIO = () => _io;

export const emitToAll = (event, payload) => { if (_io) _io.emit(event, payload); };
export const emitToRoom = (room, event, payload) => { if (_io) _io.to(room).emit(event, payload); };
