import 'bootstrap.dart';
import 'core/env.dart';
import 'firebase_options_prod.dart';

/// `flutter build apk --flavor prod -t lib/main_prod.dart --dart-define=...`
Future<void> main() =>
    bootstrap(Flavor.prod, DefaultFirebaseOptions.currentPlatform);
