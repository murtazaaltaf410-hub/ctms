import 'package:firebase_core/firebase_core.dart';

/// Firebase web app config from `--dart-define`. These values are public
/// identifiers, but they are still injected at build time per flavour rather
/// than committed. Returns null when not provided, so `initFirebase()` skips
/// Firebase and the app keeps working without push.
///
/// Defines: FIREBASE_WEB_API_KEY, FIREBASE_WEB_APP_ID,
/// FIREBASE_WEB_MESSAGING_SENDER_ID, FIREBASE_WEB_PROJECT_ID,
/// FIREBASE_WEB_AUTH_DOMAIN, FIREBASE_WEB_STORAGE_BUCKET.
FirebaseOptions? webFirebaseOptionsFromDefines() {
  const apiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
  const appId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
  const senderId = String.fromEnvironment('FIREBASE_WEB_MESSAGING_SENDER_ID');
  const projectId = String.fromEnvironment('FIREBASE_WEB_PROJECT_ID');
  const authDomain = String.fromEnvironment('FIREBASE_WEB_AUTH_DOMAIN');
  const bucket = String.fromEnvironment('FIREBASE_WEB_STORAGE_BUCKET');
  if (apiKey.isEmpty || appId.isEmpty || projectId.isEmpty) return null;
  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
    authDomain: authDomain.isEmpty ? null : authDomain,
    storageBucket: bucket.isEmpty ? null : bucket,
  );
}
