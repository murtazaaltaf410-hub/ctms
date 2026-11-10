import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import 'driver_fix.dart';
import 'driver_models.dart';

class DriverRepository {
  DriverRepository(this._api);

  final ApiClient _api;

  Future<Trip?> activeTrip() async {
    final json = await _api.get('trips/active');
    return json == null ? null : Trip.fromJson(json as Json);
  }

  Future<List<RouteSummary>> routes() async {
    final json = await _api.get('routes/assigned') as Json;
    return parseList(json['items'], RouteSummary.fromJson);
  }

  /// Route line and every stop (drivers get the full stop list).
  Future<RouteDetail> route(String routeId) async =>
      RouteDetail.fromJson(await _api.get('routes/$routeId') as Json);

  Future<Trip> startTrip(String? routeId, TripDirection direction) async {
    final json = await _api.post(
      'trips/start',
      body: {'direction': direction.wire, 'route_id': ?routeId},
    );
    return Trip.fromJson(json as Json);
  }

  Future<List<WaitingStudent>> waitingStudents(String tripId) async {
    final json = await _api.get('trips/$tripId/pickups') as Json;
    return parseList(json['items'], WaitingStudent.fromJson);
  }

  /// Approved students assigned to the trip's bus (identity, no phone numbers).
  Future<List<RosterStudent>> roster(String tripId) async {
    final json = await _api.get('trips/$tripId/roster') as Json;
    return parseList(json['items'], RosterStudent.fromJson);
  }

  /// The open stop episode, or null while the bus is moving.
  Future<StopEvent?> stopEvent(String tripId) async =>
      StopEvent.tryParse(await _api.get('trips/$tripId/stop-event'));

  Future<StopEvent?> stopReason(
    String tripId,
    StopReason reason,
    String? note,
  ) async => StopEvent.tryParse(
    await _api.post(
      'trips/$tripId/stop-reason',
      body: {
        'reason': reason.wire,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    ),
  );

  Future<DriverPrefs> prefs() async =>
      DriverPrefs.fromJson(await _api.get('me/driver-prefs') as Json);

  /// `snoozeMinutes` is 0 (clear), 15, 30 or 60.
  Future<DriverPrefs> setPrefs({
    bool? stopAlertsEnabled,
    int? snoozeMinutes,
  }) async => DriverPrefs.fromJson(
    await _api.put(
      'me/driver-prefs',
      body: {
        'stop_alerts_enabled': ?stopAlertsEnabled,
        'snooze_minutes': ?snoozeMinutes,
      },
    ) as Json,
  );

  Future<DriverProfile> profile() async =>
      DriverProfile.fromJson(await _api.get('me/driver-profile') as Json);

  /// Accept or reject a pin from a student of another bus.
  Future<void> decide(String pickupId, {required bool accept}) => _api.post(
    'pickups/$pickupId/decision',
    body: {'decision': accept ? 'accept' : 'reject'},
  );

  Future<void> setStatus(Trip trip, TripStatus status, String? note) =>
      _api.post(
        'trips/${trip.id}/status',
        body: {
          'status': status.wire,
          if (note != null && note.isNotEmpty) 'note': note,
        },
      );

  Future<Trip> endTrip(Trip trip) async =>
      Trip.fromJson(await _api.post('trips/${trip.id}/end') as Json);

  Future<void> upload(String tripId, List<DriverFix> fixes) async {
    await _api.post(
      'trips/$tripId/locations',
      body: {
        'fixes': [for (final fix in fixes) fix.toJson()],
      },
    );
  }
}
