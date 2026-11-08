import 'bootstrap.dart';
import 'core/env.dart';
import 'firebase_options_staging.dart';

/// `flutter run --flavor staging -t lib/main_staging.dart --dart-define=...`
Future<void> main() =>
    bootstrap(Flavor.staging, DefaultFirebaseOptions.currentPlatform);
