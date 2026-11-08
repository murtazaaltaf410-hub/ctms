import 'json.dart';

/// `GET /config` (public, extension): minimum app version and client thresholds.
class AppConfig {
  const AppConfig({
    required this.minAppVersion,
    required this.appUpdateUrl,
    required this.alertRadiusM,
    required this.staleAfter,
    required this.offlineAfter,
    required this.wsHeartbeat,
    required this.locationBatchMax,
    required this.gpsAccuracyMaxM,
    required this.studentMoveReportM,
    required this.studentFixMaxAccuracyM,
    required this.etaDisplayCap,
    required this.timezone,
  });

  factory AppConfig.fromJson(Json json) => AppConfig(
    minAppVersion: json['min_app_version'] as String,
    appUpdateUrl: json['app_update_url'] as String?,
    alertRadiusM: toDouble(json['alert_radius_m']),
    staleAfter: _seconds(json['stale_after_s']),
    offlineAfter: _seconds(json['offline_after_s']),
    wsHeartbeat: _seconds(json['ws_heartbeat_s']),
    locationBatchMax: json['location_batch_max'] as int,
    gpsAccuracyMaxM: toDouble(json['gps_accuracy_max_m']),
    studentMoveReportM: toDouble(json['student_move_report_m']),
    studentFixMaxAccuracyM: toDouble(json['student_fix_max_accuracy_m']),
    etaDisplayCap: _seconds(json['eta_display_cap_s']),
    timezone: json['timezone'] as String,
  );

  /// Used until `/config` answers (or when the server predates it). Mirrors the
  /// server defaults (TRD thresholds); the server values always win.
  static const fallback = AppConfig(
    minAppVersion: '0.0.0',
    appUpdateUrl: null,
    alertRadiusM: 500,
    staleAfter: Duration(seconds: 30),
    offlineAfter: Duration(seconds: 120),
    wsHeartbeat: Duration(seconds: 25),
    locationBatchMax: 20,
    gpsAccuracyMaxM: 50,
    studentMoveReportM: 100,
    studentFixMaxAccuracyM: 100,
    etaDisplayCap: Duration(minutes: 30),
    timezone: 'Asia/Kolkata',
  );

  static Duration _seconds(Object? value) =>
      Duration(milliseconds: (toDouble(value) * 1000).round());

  final String minAppVersion;
  final String? appUpdateUrl;
  final double alertRadiusM;
  final Duration staleAfter;
  final Duration offlineAfter;
  final Duration wsHeartbeat;
  final int locationBatchMax;
  final double gpsAccuracyMaxM;
  final double studentMoveReportM;
  final double studentFixMaxAccuracyM;
  final Duration etaDisplayCap;
  final String timezone;
}
