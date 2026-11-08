import 'package:dio/dio.dart';

/// Every error code in the API spec (p.6-7), plus two client-side codes.
enum ApiErrorCode {
  validationError('VALIDATION_ERROR'),
  otpInvalid('OTP_INVALID'),
  otpExpired('OTP_EXPIRED'),
  tokenExpired('TOKEN_EXPIRED'),
  tokenInvalid('TOKEN_INVALID'),
  sessionReplaced('SESSION_REPLACED'),
  forbiddenRole('FORBIDDEN_ROLE'),
  notYourTrip('NOT_YOUR_TRIP'),
  notFound('NOT_FOUND'),
  tripAlreadyActive('TRIP_ALREADY_ACTIVE'),
  inUse('IN_USE'),
  lastAdmin('LAST_ADMIN'),
  polylineFailed('POLYLINE_FAILED'),
  rateLimited('RATE_LIMITED'),
  dbUnavailable('DB_UNAVAILABLE'),

  /// No response: offline, DNS failure, timeout, server asleep (N1).
  network('NETWORK'),

  /// A response that could not be mapped to a spec code.
  unknown('UNKNOWN');

  const ApiErrorCode(this.wire);

  /// The string used on the wire.
  final String wire;

  static ApiErrorCode fromWire(String? wire) => values.firstWhere(
    (c) => c.wire == wire,
    orElse: () => ApiErrorCode.unknown,
  );

  /// Worth retrying later without user action.
  bool get isTransient =>
      this == network || this == dbUnavailable || this == rateLimited;
}

/// A failed API call, mapped from the spec envelope `{"error":{"code","message"}}`.
class ApiException implements Exception {
  const ApiException(
    this.code, {
    this.message,
    this.statusCode,
    this.retryAfter,
  });

  /// Maps any [DioException] (with or without a response) to an [ApiException].
  factory ApiException.fromDio(DioException e) {
    final response = e.response;
    if (response == null) {
      return ApiException(ApiErrorCode.network, message: e.message);
    }
    final status = response.statusCode;
    String? wire;
    String? message;
    final data = response.data;
    if (data is Map && data['error'] is Map) {
      final error = data['error'] as Map;
      wire = error['code'] as String?;
      message = error['message'] as String?;
    }
    var code = ApiErrorCode.fromWire(wire);
    if (code == ApiErrorCode.unknown) code = _fromStatus(status);
    return ApiException(
      code,
      message: message,
      statusCode: status,
      retryAfter: _retryAfter(response.headers.value('retry-after')),
    );
  }

  final ApiErrorCode code;

  /// The server's message (may be technical). Prefer [userMessage] in the UI.
  final String? message;
  final int? statusCode;

  /// From the `Retry-After` header on 429 (seconds form).
  final Duration? retryAfter;

  static ApiErrorCode _fromStatus(int? status) => switch (status) {
    400 => ApiErrorCode.validationError,
    401 => ApiErrorCode.tokenInvalid,
    403 => ApiErrorCode.forbiddenRole,
    404 => ApiErrorCode.notFound,
    429 => ApiErrorCode.rateLimited,
    503 => ApiErrorCode.dbUnavailable,
    _ => ApiErrorCode.unknown,
  };

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// Plain-language text for the user.
  String get userMessage => switch (code) {
    ApiErrorCode.validationError =>
      'Something in the form is missing or not valid. Check it and try again.',
    ApiErrorCode.otpInvalid =>
      'That code is not right. Check the SMS and try again.',
    ApiErrorCode.otpExpired =>
      'That code has expired. Ask for a new code and try again.',
    ApiErrorCode.tokenExpired || ApiErrorCode.tokenInvalid =>
      'Your session has ended. Please sign in again.',
    ApiErrorCode.sessionReplaced =>
      'You were signed out because this account signed in on another device.',
    ApiErrorCode.forbiddenRole => 'Your account is not allowed to do this.',
    ApiErrorCode.notYourTrip => 'This trip belongs to another driver.',
    ApiErrorCode.notFound => 'This item no longer exists.',
    ApiErrorCode.tripAlreadyActive => 'A trip is already running for this bus.',
    ApiErrorCode.inUse => 'This is in use by a running trip. Try again later.',
    ApiErrorCode.lastAdmin => 'The last admin cannot be removed.',
    ApiErrorCode.polylineFailed =>
      'The route line could not be generated. It was saved as a draft.',
    ApiErrorCode.rateLimited =>
      retryAfter == null
          ? 'Too many attempts. Please wait a little and try again.'
          : 'Too many attempts. Try again in ${formatWait(retryAfter!)}.',
    ApiErrorCode.dbUnavailable =>
      'The service is busy right now. Please try again shortly.',
    ApiErrorCode.network =>
      'Cannot reach the server. Check your internet connection.',
    ApiErrorCode.unknown => 'Something went wrong. Please try again.',
  };

  /// "45 seconds", "1 minute", "4 minutes".
  static String formatWait(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '$s second${s == 1 ? '' : 's'}';
    final m = (s / 60).ceil();
    return '$m minute${m == 1 ? '' : 's'}';
  }

  @override
  String toString() =>
      'ApiException(${code.wire}, status: $statusCode, message: $message)';
}
