import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';

class AnnouncementPage {
  const AnnouncementPage({required this.items, required this.nextCursor});

  final List<Announcement> items;
  final String? nextCursor;
}

class AlertSettings {
  const AlertSettings({required this.enabled});

  final bool enabled;

  factory AlertSettings.fromJson(Json json) =>
      AlertSettings(enabled: json['enabled'] as bool);
}

class SentAlert {
  const SentAlert({
    required this.tripId,
    required this.busId,
    required this.busLabel,
    required this.routeName,
    required this.sentAt,
  });

  factory SentAlert.fromJson(Json json) => SentAlert(
    tripId: json['trip_id'] as String,
    busId: json['bus_id'] as String,
    busLabel: json['bus_label'] as String,
    routeName: json['route_name'] as String,
    sentAt: parseTime(json['sent_at']),
  );

  final String tripId;
  final String busId;
  final String busLabel;
  final String routeName;
  final DateTime sentAt;
}

class StudentRepository {
  StudentRepository(this._api);

  final ApiClient _api;

  Future<List<RouteSummary>> routes() async {
    final json = await _api.get('routes') as Json;
    return parseList(json['items'], RouteSummary.fromJson);
  }

  Future<RouteDetail> route(String routeId) async =>
      RouteDetail.fromJson(await _api.get('routes/$routeId') as Json);

  Future<StopEta> eta(String stopId) async =>
      StopEta.fromJson(await _api.get('stops/$stopId/eta') as Json);

  Future<AnnouncementPage> announcements({String? cursor}) async {
    final json = await _api.get(
      'announcements',
      query: switch (cursor) {
        final value? => {'limit': 50, 'cursor': value},
        null => {'limit': 50},
      },
    ) as Json;
    return AnnouncementPage(
      items: parseList(json['items'], Announcement.fromJson),
      nextCursor: json['next_cursor'] as String?,
    );
  }

  Future<AlertSettings> alertSettings() async =>
      AlertSettings.fromJson(await _api.get('me/alert-settings') as Json);

  Future<AlertSettings> setAlertEnabled(bool enabled) async =>
      AlertSettings.fromJson(
        await _api.put('me/alert-settings', body: {'enabled': enabled}) as Json,
      );

  Future<void> uploadLocation({
    required double lat,
    required double lng,
    required double accuracy,
    required DateTime recordedAt,
  }) => _api.post(
    'me/location',
    body: {
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
    },
  );

  Future<List<SentAlert>> sentAlerts() async {
    final json = await _api.get('me/alerts', query: {'limit': 20}) as Json;
    return parseList(json['items'], SentAlert.fromJson);
  }

  Future<Pickup?> myPickup() async {
    final json = await _api.get('me/pickup');
    return json == null ? null : Pickup.fromJson(json as Json);
  }

  Future<Pickup> createPickup({
    required String routeId,
    required TripDirection direction,
    required double lat,
    required double lng,
    String? label,
  }) async => Pickup.fromJson(
    await _api.post(
      'pickups',
      body: {
        'route_id': routeId,
        'direction': direction.wire,
        'lat': lat,
        'lng': lng,
        'label': ?label,
      },
    ) as Json,
  );

  Future<void> cancelPickup(String id) => _api.delete('pickups/$id');

  /// Null before the first submit.
  Future<StudentRegistration?> registration() async {
    final json = await _api.get('me/registration');
    return json == null ? null : StudentRegistration.fromJson(json as Json);
  }

  Future<StudentRegistration> submitRegistration(
    RegistrationInput input,
  ) async => StudentRegistration.fromJson(
    await _api.put('me/registration', body: input.toJson()) as Json,
  );

  /// The route closest to a point, or null when none is near.
  Future<NearestRoute?> nearestRoute(double lat, double lng) async {
    final json = await _api.get(
      'routes/nearest',
      query: {'lat': lat, 'lng': lng},
    );
    return json == null ? null : NearestRoute.fromJson(json as Json);
  }

  /// `PUT /me/registration/photo`: the raw JPEG body (not JSON/multipart).
  Future<StudentRegistration> uploadRegistrationPhoto(Uint8List jpeg) async {
    try {
      final response = await _api.dio.put<dynamic>(
        'me/registration/photo',
        data: jpeg,
        options: Options(
          contentType: 'image/jpeg',
          headers: {Headers.contentLengthHeader: jpeg.length},
        ),
      );
      return StudentRegistration.fromJson(response.data as Json);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Image bytes from an authenticated photo endpoint; null when there is no
  /// photo (404). `GET /students/{id}/photo`, `GET /drivers/{id}/photo`.
  Future<Uint8List?> _photo(String path) async {
    try {
      final response = await _api.dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      return bytes == null || bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } on DioException catch (e) {
      final error = ApiException.fromDio(e);
      if (error.code == ApiErrorCode.notFound) return null;
      throw error;
    }
  }

  Future<Uint8List?> studentPhoto(String userId) =>
      _photo('students/$userId/photo');

  Future<Uint8List?> driverPhoto(String driverId) =>
      _photo('drivers/$driverId/photo');

  Future<BusCard> busCard() async =>
      BusCard.fromJson(await _api.get('me/bus-card') as Json);

  /// Null until a bus is assigned.
  Future<MyBus?> myBus() async {
    final json = await _api.get('me/bus');
    return json == null ? null : MyBus.fromJson(json as Json);
  }

  /// ETAs to the waiting pickup pin, else to the route's first stop.
  Future<MyEta> myEta() async =>
      MyEta.fromJson(await _api.get('me/eta') as Json);

  /// The latest request, or null when the student never asked.
  Future<DeregistrationRequest?> deregistration() async {
    final json = await _api.get('me/deregistration-request');
    return json == null ? null : DeregistrationRequest.fromJson(json as Json);
  }

  Future<DeregistrationRequest> requestDeregistration(String? reason) async =>
      DeregistrationRequest.fromJson(
        await _api.post('me/deregistration-request', body: {'reason': ?reason})
            as Json,
      );
}
