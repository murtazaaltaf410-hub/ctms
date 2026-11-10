// Static + executable proof that the service worker only caches allow-listed
// same-origin static GETs and never API/auth/WS/location/etc.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('web/ctms_sw.js').readAsStringSync();

  test('exactly one cache write, in storeStatic, behind the allow check', () {
    expect(RegExp(r'\.put\(').allMatches(src).length, 1);
    expect(
      RegExp(r'\.add\(|\.addAll\(').allMatches(src).length,
      1,
      reason: 'only the fixed PRECACHE list',
    );
    final fn = RegExp(r'function storeStatic[\s\S]*?\n}')
        .firstMatch(src)!
        .group(0)!;
    expect(fn, contains('.put('));
    expect(RegExp(r'storeStatic\(').allMatches(src).length, 2);
    expect(
      src,
      contains('isAllowListed(request) && isCacheableResponse(response)'),
    );
    expect(src, contains('if (!isAllowListed(request)) return;'));
  });

  test('denylist covers the sensitive classes', () {
    for (final p in [
      '/api',
      '/ws',
      '/auth',
      '/token',
      '/location',
      '/pickup',
      '/roster',
      '/trips',
      '/buses',
      '/firebase',
      '/maps',
      '/tiles',
    ]) {
      expect(src, contains("'$p'"), reason: p);
    }
    for (final h in [
      'maps.googleapis.com',
      'maps.gstatic.com',
      'firebaseapp.com',
    ]) {
      expect(src, contains("'$h'"), reason: h);
    }
    expect(src, contains("has('authorization')"));
  });

  test('no automatic skipWaiting in install handler', () {
    final install = RegExp(r"addEventListener\('install'[\s\S]*?\n}\);")
        .firstMatch(src)!
        .group(0)!
        .replaceAll(RegExp(r'//.*'), '');
    expect(install, isNot(contains('skipWaiting')));
  });

  test('node policy check', () async {
    ProcessResult r;
    try {
      r = await Process.run('node', ['test/core/pwa/sw_policy_check.js']);
    } on ProcessException {
      markTestSkipped('node unavailable');
      return;
    }
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  });
}
