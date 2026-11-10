import 'package:ctms/core/location/fix_outbox.dart';
import 'package:ctms/core/location/location_types.dart';
import 'package:flutter_test/flutter_test.dart';

StudentFix fix(DateTime at, {double accuracy = 10}) =>
    StudentFix(lat: 34.1, lng: 74.8, accuracy: accuracy, recordedAt: at);

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);
  FixOutbox outbox({int capacity = 3}) => FixOutbox(
    maxAge: const Duration(seconds: 300),
    maxAccuracyM: 100,
    capacity: capacity,
  );

  test('refuses fixes that are not accurate enough', () {
    final o = outbox();
    expect(o.add(fix(now, accuracy: 100), now), isFalse);
    expect(o.add(fix(now, accuracy: 250), now), isFalse);
    expect(o.length, 0);
  });

  test('refuses and expires fixes older than the freshness threshold', () {
    final o = outbox();
    final old = now.subtract(const Duration(seconds: 301));
    expect(o.add(fix(old), now), isFalse);

    final ok = fix(now.subtract(const Duration(seconds: 290)));
    expect(o.add(ok, now), isTrue);
    expect(o.newestFresh(now), same(ok));
    // 20 s later the same fix is stale: discarded, never replayed.
    expect(o.newestFresh(now.add(const Duration(seconds: 20))), isNull);
    expect(o.length, 0);
  });

  test('returns only the newest fresh fix', () {
    final o = outbox();
    final a = fix(now.subtract(const Duration(seconds: 60)));
    final b = fix(now.subtract(const Duration(seconds: 10)));
    o
      ..add(b, now)
      ..add(a, now);
    expect(o.newestFresh(now), same(b));
  });

  test('is bounded: drops the oldest beyond capacity', () {
    final o = outbox(capacity: 2);
    for (var i = 0; i < 5; i++) {
      o.add(fix(now.subtract(Duration(seconds: 50 - i))), now);
    }
    expect(o.length, 2);
  });

  test('clear empties it', () {
    final o = outbox()..add(fix(now), now);
    o.clear();
    expect(o.newestFresh(now), isNull);
  });
}
