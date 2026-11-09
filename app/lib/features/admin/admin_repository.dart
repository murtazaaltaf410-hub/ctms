import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/json.dart';
import '../../core/models/registration.dart';
import '../../core/models/trip.dart';
import 'admin_models.dart';

/// Admin-only HTTP boundary. All paths are relative to `/api/v1`.
class AdminRepository {
  const AdminRepository(this._api);
  final ApiClient _api;

  Future<List<T>> _page<T>(
    String path,
    T Function(Json) fromJson, {
    Map<String, dynamic>? query,
  }) async {
    final body = await _api.get(path, query: query) as Json;
    return (body['items'] as List).map((e) => fromJson(e as Json)).toList();
  }

  Future<List<AdminBus>> buses() => _page('admin/buses', AdminBus.fromJson);
  Future<List<AdminDriver>> drivers() =>
      _page('admin/drivers', AdminDriver.fromJson);
  Future<List<AdminRoute>> routes() =>
      _page('admin/routes', AdminRoute.fromJson);
  Future<AdminRoute> route(String id) async =>
      AdminRoute.fromJson(await _api.get('admin/routes/$id') as Json);
  Future<List<AdminSchedule>> schedules() =>
      _page('admin/schedules', AdminSchedule.fromJson);
  Future<List<AdminAnnouncement>> announcements() =>
      _page('announcements', AdminAnnouncement.fromJson);
  Future<List<AdminAccount>> admins() =>
      _page('admin/admins', AdminAccount.fromJson);
  Future<List<TripReport>> trips({String? busId}) =>
      _page('admin/trips', TripReport.fromJson, query: {'bus_id': ?busId});
  Future<TripPath> tripPath(String id) async =>
      TripPath.fromJson(await _api.get('admin/trips/$id/path') as Json);
  Future<double> alertRadius() async => (await settings()).alertRadiusM;
  Future<CampusSettings> settings() async =>
      CampusSettings.fromJson(await _api.get('admin/settings') as Json);
  Future<CampusSettings> updateSettings(Map<String, dynamic> changes) async =>
      CampusSettings.fromJson(
        await _api.put('admin/settings', body: changes) as Json,
      );

  Future<void> createBus({
    required String label,
    required String plate,
    String? routeId,
    int? capacity,
  }) => _api.post(
    'admin/buses',
    body: {
      'label': label,
      'plate': plate,
      'active': true,
      'default_route_id': ?routeId,
      'capacity': ?capacity,
    },
  );
  Future<void> updateBus(String id, Map<String, dynamic> changes) =>
      _api.patch('admin/buses/$id', body: changes);

  // --- students (ADR-10) ---------------------------------------------------
  Future<CursorPage<AdminStudent>> students({
    RegistrationStatus? status,
    String? routeId,
    String? busId,
    String? query,
    String? cursor,
    int limit = 50,
  }) async => CursorPage.fromJson(
    await _api.get(
      'admin/students',
      query: {
        'limit': limit,
        'status': ?status?.name,
        'route_id': ?routeId,
        'bus_id': ?busId,
        'q': ?((query ?? '').trim().isEmpty ? null : query!.trim()),
        'cursor': ?cursor,
      },
    ) as Json,
    AdminStudent.fromJson,
  );

  Future<StudentSummary> studentSummary() async =>
      StudentSummary.fromJson(await _api.get('admin/students/summary') as Json);

  Future<AdminStudent> approveStudent(String id, String busId) async =>
      AdminStudent.fromJson(
        await _api.post('admin/students/$id/approve', body: {'bus_id': busId})
            as Json,
      );

  Future<AdminStudent> reassignStudent(String id, String busId) async =>
      AdminStudent.fromJson(
        await _api.post('admin/students/$id/reassign', body: {'bus_id': busId})
            as Json,
      );

  Future<AdminStudent> rejectStudent(String id, String note) async =>
      AdminStudent.fromJson(
        await _api.post('admin/students/$id/reject', body: {'note': note})
            as Json,
      );

  /// Returns the one-time temporary password.
  Future<String> createDriver(AdminDriverInput input) async {
    final body = await _api.post(
      'admin/drivers',
      body: {...input.toJson(), 'active': true},
    ) as Json;
    return body['temporary_password'] as String;
  }

  Future<void> updateDriver(String id, Map<String, dynamic> changes) =>
      _api.patch('admin/drivers/$id', body: changes);

  Future<List<String>> driverRouteIds(String id) async {
    final body = await _api.get('admin/drivers/$id/routes') as Json;
    return (body['route_ids'] as List).cast<String>();
  }

  Future<void> replaceDriverRoutes(String id, List<String> routeIds) =>
      _api.put('admin/drivers/$id/routes', body: {'route_ids': routeIds});

  /// New temporary password (shown once); unlocks the account and signs the
  /// driver out everywhere.
  Future<String> resetDriverPassword(String id) async {
    final body = await _api.post('admin/drivers/$id/reset-password') as Json;
    return body['temporary_password'] as String;
  }

  Future<AdminRoute> createRoute({
    required String name,
    required List<Map<String, Object>> stops,
  }) async => AdminRoute.fromJson(
    await _api.post(
      'admin/routes',
      body: {'name': name, 'active': true, 'stops': stops},
    ) as Json,
  );
  Future<AdminRoute> retryRoute(String id) async => AdminRoute.fromJson(
    await _api.patch('admin/routes/$id', body: {'regenerate': true}) as Json,
  );
  Future<void> updateRoute(String id, Map<String, dynamic> changes) =>
      _api.patch('admin/routes/$id', body: changes);
  Future<void> addStop(String routeId, Map<String, Object> stop) =>
      _api.post('admin/routes/$routeId/stops', body: stop);
  Future<void> updateStop(String stopId, Map<String, dynamic> changes) =>
      _api.patch('admin/stops/$stopId', body: changes);
  Future<void> createSchedule({
    required String routeId,
    required String time,
    required List<int> days,
    TripDirection direction = TripDirection.toCampus,
  }) => _api.post(
    'admin/schedules',
    body: {
      'route_id': routeId,
      'departure_time': time,
      'days_of_week': days,
      'direction': direction.wire,
      'active': true,
    },
  );
  Future<void> updateSchedule(String id, Map<String, dynamic> changes) =>
      _api.patch('admin/schedules/$id', body: changes);
  Future<void> createAnnouncement({
    required String title,
    required String body,
    required bool urgent,
    required bool push,
  }) => _api.post(
    'admin/announcements',
    body: {'title': title, 'body': body, 'urgent': urgent, 'push': push},
  );
  Future<void> updateAnnouncement(String id, Map<String, dynamic> changes) =>
      _api.patch('admin/announcements/$id', body: changes);
  Future<void> deleteAnnouncement(String id) =>
      _api.delete('admin/announcements/$id');
  Future<void> addAdmin(String email) =>
      _api.post('admin/admins', body: {'email': email});
  Future<void> removeAdmin(String id) => _api.delete('admin/admins/$id');
  Future<void> setAlertRadius(double metres) =>
      _api.put('admin/settings', body: {'alert_radius_m': metres});

  /// Text is deliberately exposed rather than a device-specific share/save flow.
  /// It remains usable from a desktop browser and can be pasted into a spreadsheet.
  Future<String> tripsCsv({String? busId}) async {
    try {
      final response = await _api.dio.get<String>(
        'admin/reports/trips.csv',
        queryParameters: {'bus_id': ?busId},
        options: Options(responseType: ResponseType.plain),
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
