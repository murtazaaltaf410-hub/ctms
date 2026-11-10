import 'dart:async';

import 'page_signals_types.dart';

/// Native: always visible and online, never emits. Android keeps its existing
/// geolocator / foreground-service behaviour.
class _NativePageSignals implements PageSignals {
  @override
  bool get isVisible => true;

  @override
  bool get isOnline => true;

  @override
  Stream<PageSignal> get signals => const Stream.empty();

  @override
  void dispose() {}
}

PageSignals createPageSignals() => _NativePageSignals();
