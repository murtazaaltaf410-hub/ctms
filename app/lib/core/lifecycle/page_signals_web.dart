import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'page_signals_types.dart';

class _WebPageSignals implements PageSignals {
  _WebPageSignals() {
    _on(web.document, 'visibilitychange', (_) {
      _controller.add(isVisible ? PageSignal.visible : PageSignal.hidden);
    });
    _on(web.window, 'online', (_) => _controller.add(PageSignal.online));
    _on(web.window, 'offline', (_) => _controller.add(PageSignal.offline));
    _on(web.window, 'pageshow', (_) => _controller.add(PageSignal.pageshow));
    // `pagehide` fires when the page is frozen / enters the back-forward
    // cache; visibilitychange usually fires too, so this is belt and braces.
    _on(web.window, 'pagehide', (_) => _controller.add(PageSignal.hidden));
  }

  final _controller = StreamController<PageSignal>.broadcast();
  final _removers = <void Function()>[];

  void _on(web.EventTarget target, String type, void Function(web.Event) fn) {
    final js = fn.toJS;
    target.addEventListener(type, js);
    _removers.add(() => target.removeEventListener(type, js));
  }

  @override
  bool get isVisible => web.document.visibilityState == 'visible';

  @override
  bool get isOnline => web.window.navigator.onLine;

  @override
  Stream<PageSignal> get signals => _controller.stream;

  @override
  void dispose() {
    for (final r in _removers) {
      r();
    }
    _removers.clear();
    unawaited(_controller.close());
  }
}

PageSignals createPageSignals() => _WebPageSignals();
