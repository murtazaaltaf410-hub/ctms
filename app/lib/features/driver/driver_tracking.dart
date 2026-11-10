import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import 'driver_fix.dart';
import 'driver_repository.dart';

abstract interface class FixBuffer {
  Future<void> add(DriverFix fix);
  Future<List<DriverFix>> next(String tripId, int limit);
  Future<void> remove(List<DriverFix> fixes);
  Future<int> count(String tripId);

  /// Drops every buffered fix of a trip (the trip ended on the server).
  Future<void> clearTrip(String tripId);
}

class SqliteFixBuffer implements FixBuffer {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final path = '${await getDatabasesPath()}/ctms_driver.db';
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE driver_fixes (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        fix_id TEXT UNIQUE NOT NULL,
        trip_id TEXT NOT NULL,
        lat REAL NOT NULL, lng REAL NOT NULL, accuracy REAL NOT NULL,
        speed REAL, heading REAL, recorded_at TEXT NOT NULL
      )''');
      },
    );
    return _db!;
  }

  @override
  Future<void> add(DriverFix fix) async {
    await (await _database).insert(
      'driver_fixes',
      fix.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<List<DriverFix>> next(String tripId, int limit) async {
    final rows = await (await _database).query(
      'driver_fixes',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return [for (final row in rows) DriverFix.fromRow(row)];
  }

  @override
  Future<void> remove(List<DriverFix> fixes) async {
    if (fixes.isEmpty) return;
    final ids = fixes.map((f) => f.id).toList(growable: false);
    final marks = List.filled(ids.length, '?').join(',');
    await (await _database).delete(
      'driver_fixes',
      where: 'fix_id IN ($marks)',
      whereArgs: ids,
    );
  }

  @override
  Future<void> clearTrip(String tripId) async {
    await (await _database).delete(
      'driver_fixes',
      where: 'trip_id = ?',
      whereArgs: [tripId],
    );
  }

  @override
  Future<int> count(String tripId) async =>
      Sqflite.firstIntValue(
        await (await _database).rawQuery(
          'SELECT COUNT(*) FROM driver_fixes WHERE trip_id = ?',
          [tripId],
        ),
      ) ??
      0;
}

enum LocationGate { ready, serviceOff, denied, deniedForever, approximate }

class DriverLocationService {
  Future<LocationGate> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationGate.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationGate.deniedForever;
    }
    if (permission == LocationPermission.denied) return LocationGate.denied;
    if (await Geolocator.getLocationAccuracy() ==
        LocationAccuracyStatus.reduced) {
      return LocationGate.approximate;
    }
    return LocationGate.ready;
  }

  Stream<Position> positions() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    ),
  );
}

class DriverTracker {
  DriverTracker(this._repository, this._buffer, this._locations);

  final DriverRepository _repository;
  final FixBuffer _buffer;
  final DriverLocationService _locations;
  StreamSubscription<Position>? _positions;
  Timer? _retryTimer;
  DateTime? _retryAt;
  DateTime? _lastCapturedAt;
  bool _flushing = false;
  DriverFix? _latestFix;
  final _live = StreamController<DriverFix>.broadcast(sync: true);

  /// Every GPS reading of the active trip, unthrottled. The upload path below
  /// samples every 5-15 s; the driver's own map follows this stream instead so
  /// the bus moves as the phone does.
  Stream<DriverFix> get livePositions => _live.stream;

  /// Most recent reading for a map that subscribes after tracking began.
  DriverFix? get latestFix => _latestFix;

  /// Publishes a reading to [livePositions] (tests drive it directly).
  @visibleForTesting
  void publish(DriverFix fix) {
    _latestFix = fix;
    if (!_live.isClosed) _live.add(fix);
  }

  /// Called when an upload finds the trip gone (404): the server ended it.
  void Function(String tripId)? onTripGone;

  Future<void> start(Trip trip, int batchLimit) async {
    _initialiseForegroundService();
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isRunningService) {
      final result = await FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.location],
        notificationTitle: 'CTMS trip in progress',
        notificationText: 'Sharing this bus location while the trip is active.',
        callback: driverForegroundTaskCallback,
      );
      if (result is ServiceRequestFailure) {
        throw StateError('Could not start location tracking: ${result.error}');
      }
    }
    await _positions?.cancel();
    _positions = _locations.positions().listen((position) async {
      publish(DriverFix.fromPosition(trip.id, position));
      final now = DateTime.now();
      final interval = position.speed > 0.5
          ? const Duration(seconds: 5)
          : const Duration(seconds: 15);
      if (_lastCapturedAt != null &&
          now.difference(_lastCapturedAt!) < interval) {
        return;
      }
      _lastCapturedAt = now;
      await _buffer.add(DriverFix.fromPosition(trip.id, position));
      await flush(trip.id, batchLimit);
    });
  }

  Future<void> recover(Trip trip, int batchLimit) => start(trip, batchLimit);

  Future<void> flush(String tripId, int batchLimit) async {
    if (_flushing || (_retryAt?.isAfter(DateTime.now()) ?? false)) return;
    _flushing = true;
    try {
      while (true) {
        final fixes = await _buffer.next(
          tripId,
          batchLimit.clamp(1, 20).toInt(),
        );
        if (fixes.isEmpty) return;
        await _repository.upload(tripId, fixes);
        // A 200 gives an accepted or rejected result per fix; both are final.
        await _buffer.remove(fixes);
      }
    } on ApiException catch (e) {
      if (e.code.isTransient) {
        final delay = e.retryAfter ?? const Duration(seconds: 15);
        _retryAt = DateTime.now().add(delay);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () => unawaited(flush(tripId, batchLimit)));
        return;
      }
      if (e.code == ApiErrorCode.notFound || e.statusCode == 404) {
        onTripGone?.call(tripId);
        return;
      }
      // Authentication failures already flow through AuthInterceptor; do not
      // let a location-stream callback become an unhandled asynchronous error.
      return;
    } finally {
      _flushing = false;
    }
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _positions?.cancel();
    _positions = null;
    _lastCapturedAt = null;
    _latestFix = null;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  void _initialiseForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ctms_driver_tracking',
        channelName: 'Driver trip tracking',
        channelDescription: 'Visible while a driver trip is active',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }
}

/// The foreground service must install a task handler even though location
/// collection stays in the app isolate, where the authenticated HTTP client
/// and SQLite buffer live. Its visible Android service keeps that work alive.
@pragma('vm:entry-point')
void driverForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_DriverForegroundTaskHandler());
}

class _DriverForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
