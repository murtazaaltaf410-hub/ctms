/// Browser page events the app cares about (plan 5.2 rule 4).
enum PageSignal { hidden, visible, online, offline, pageshow }

/// Source of page visibility / connectivity events. The browser implementation
/// listens to `visibilitychange`, `online`, `offline` and `pageshow`; the
/// native implementation never emits (Android keeps its existing behaviour:
/// the foreground service owns background work, not the page).
abstract interface class PageSignals {
  bool get isVisible;
  bool get isOnline;
  Stream<PageSignal> get signals;
  void dispose();
}
