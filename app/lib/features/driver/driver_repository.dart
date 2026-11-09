import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import 'driver_fix.dart';

class DriverRepository {
  DriverRepository(this._api);

  final ApiClient _api;

  Future<Trip?> activeTrip() async {
    final json = await _api.get('trips/active');
    return json == null ? null : Trip.fromJson(json as Json);
  }

  Future<List<RouteSummary>> routes() async {
    final json = await _api.get('routes') as Json;
    return parseList(json['items'], RouteSummary.fromJson);
  }

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

  /// Approved students assigned to the trip's bus (name and department only).
  Future<List<RosterStudent>> roster(String tripId) async {
    final json = await _api.get('trips/$tripId/roster') as Json;
    return parseList(json['items'], RosterStudent.fromJson);
  }

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
