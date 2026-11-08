import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/api/api_client.dart';
import '../core/api/api_exception.dart';
import '../core/models/models.dart';

/// `GET /config` (public). Falls back to [AppConfig.fallback] when the server
/// is unreachable or doesn't have the endpoint (404), so the app always starts.
final appConfigProvider = FutureProvider<AppConfig>((ref) async {
  try {
    final json = await ref.read(apiClientProvider).get('config', auth: false);
    return AppConfig.fromJson(json as Json);
  } on ApiException {
    return AppConfig.fallback;
  } on TypeError {
    return AppConfig.fallback; // unexpected shape: don't block the app
  }
});

/// This build's version (`version:` in pubspec, without `+build`).
final appVersionProvider = FutureProvider<String>(
  (ref) async => (await PackageInfo.fromPlatform()).version,
);

class VersionCheck {
  const VersionCheck({required this.updateRequired, this.updateUrl});

  final bool updateRequired;
  final String? updateUrl;
}

/// Blocks old builds with the "please update" screen (runbook "Mobile apps" 3).
final versionCheckProvider = FutureProvider<VersionCheck>((ref) async {
  final config = await ref.watch(appConfigProvider.future);
  final String version;
  try {
    version = await ref.watch(appVersionProvider.future);
  } catch (_) {
    return const VersionCheck(updateRequired: false);
  }
  return VersionCheck(
    updateRequired: compareVersions(version, config.minAppVersion) < 0,
    updateUrl: config.appUpdateUrl,
  );
});

/// Compares dotted numeric versions; ignores `-suffix` and `+build`.
/// `1.2.0` == `1.2`, `1.10.0` > `1.9.9`.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp('[-+]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
