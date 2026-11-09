import '../../core/api/api_client.dart';
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

  Future<void> deleteAccount() => _api.delete('me');

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
}
