import 'package:ctms/core/api/api_exception.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _error(int status, Object? data, {String? retryAfter}) {
  final options = RequestOptions(path: 'x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: data,
      headers: Headers.fromMap({
        if (retryAfter != null) 'retry-after': [retryAfter],
      }),
    ),
  );
}

Map<String, dynamic> _envelope(String code) => {
  'error': {'code': code, 'message': 'msg for $code'},
};

void main() {
  // Every code in the API spec (p.6-7) with the status the server uses.
  const spec = {
    'VALIDATION_ERROR': (400, ApiErrorCode.validationError),
    'INVALID_CREDENTIALS': (401, ApiErrorCode.invalidCredentials),
    'TOKEN_EXPIRED': (401, ApiErrorCode.tokenExpired),
    'TOKEN_INVALID': (401, ApiErrorCode.tokenInvalid),
    'SESSION_REPLACED': (401, ApiErrorCode.sessionReplaced),
    'FORBIDDEN_ROLE': (403, ApiErrorCode.forbiddenRole),
    'NOT_YOUR_TRIP': (403, ApiErrorCode.notYourTrip),
    'NOT_FOUND': (404, ApiErrorCode.notFound),
    'TRIP_ALREADY_ACTIVE': (409, ApiErrorCode.tripAlreadyActive),
    'IN_USE': (409, ApiErrorCode.inUse),
    'LAST_ADMIN': (409, ApiErrorCode.lastAdmin),
    'POLYLINE_FAILED': (422, ApiErrorCode.polylineFailed),
    'RATE_LIMITED': (429, ApiErrorCode.rateLimited),
    'DB_UNAVAILABLE': (503, ApiErrorCode.dbUnavailable),
  };

  group('spec error envelope', () {
    for (final MapEntry(key: wire, value: (status, code)) in spec.entries) {
      test('$wire → $code', () {
        final e = ApiException.fromDio(_error(status, _envelope(wire)));
        expect(e.code, code);
        expect(e.code.wire, wire);
        expect(e.statusCode, status);
        expect(e.message, 'msg for $wire');
        expect(e.userMessage, isNotEmpty);
      });
    }

    test('the enum covers every spec code', () {
      final wires = ApiErrorCode.values.map((c) => c.wire).toSet();
      expect(wires, containsAll(spec.keys));
    });
  });

  test('RATE_LIMITED carries Retry-After and says how long to wait', () {
    final e = ApiException.fromDio(
      _error(429, _envelope('RATE_LIMITED'), retryAfter: '120'),
    );
    expect(e.retryAfter, const Duration(seconds: 120));
    expect(e.userMessage, contains('2 minutes'));

    final short = ApiException.fromDio(
      _error(429, _envelope('RATE_LIMITED'), retryAfter: '45'),
    );
    expect(short.userMessage, contains('45 seconds'));
  });

  test('no response → network', () {
    final e = ApiException.fromDio(
      DioException(
        requestOptions: RequestOptions(path: 'x'),
        type: DioExceptionType.connectionError,
      ),
    );
    expect(e.code, ApiErrorCode.network);
    expect(e.code.isTransient, isTrue);
  });

  test('no envelope falls back to the HTTP status', () {
    expect(
      ApiException.fromDio(_error(503, 'down')).code,
      ApiErrorCode.dbUnavailable,
    );
    expect(ApiException.fromDio(_error(404, null)).code, ApiErrorCode.notFound);
    expect(
      ApiException.fromDio(_error(500, {'detail': 'x'})).code,
      ApiErrorCode.unknown,
    );
  });

  test('unknown wire code with a known status uses the status', () {
    final e = ApiException.fromDio(_error(401, _envelope('SOMETHING_NEW')));
    expect(e.code, ApiErrorCode.tokenInvalid);
  });
}
