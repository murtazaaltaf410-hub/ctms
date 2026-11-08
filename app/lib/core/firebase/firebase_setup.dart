import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Initialises Firebase if this flavour has real options.
///
/// Returns false (and the app keeps working without push or Firebase phone
/// auth) while `lib/firebase_options_<flavor>.dart` is still the stub, or if
/// initialisation fails.
Future<bool> initFirebase(FirebaseOptions? options) async {
  if (options == null) {
    debugPrint('Firebase not configured: run flutterfire configure (README).');
    return false;
  }
  try {
    await Firebase.initializeApp(options: options);
    return true;
  } catch (e) {
    debugPrint('Firebase init failed, continuing without it: $e');
    return false;
  }
}

/// True once Firebase is initialised. Overridden in `bootstrap()`.
final firebaseReadyProvider = Provider<bool>((ref) => false);
