import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/env.dart';
import 'core/firebase/firebase_setup.dart';
import 'core/platform/app_platform.dart';
import 'core/platform/foreground_init.dart';
import 'push/push_service.dart';

/// Shared start-up for every flavour entry point (`main_<flavor>.dart`).
Future<void> bootstrap(Flavor flavor, FirebaseOptions? firebaseOptions) async {
  WidgetsFlutterBinding.ensureInitialized();
  initForegroundCommunication();
  final firebaseReady = await initFirebase(firebaseOptions);
  if (firebaseReady && pushRegistrationSupported(currentAppPlatform())) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  runApp(
    ProviderScope(
      overrides: [
        envProvider.overrideWithValue(Env.fromDefines(flavor)),
        firebaseReadyProvider.overrideWithValue(firebaseReady),
      ],
      child: const CtmsApp(),
    ),
  );
}
