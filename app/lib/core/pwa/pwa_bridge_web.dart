import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'pwa_bridge_types.dart';

@JS('__ctmsPwa')
external JSObject? get _api;

bool _flag(JSObject o, String k) {
  final v = o.getProperty<JSAny?>(k.toJS);
  return v != null && v.isA<JSBoolean>() && (v as JSBoolean).toDart;
}

class _WebPwaBridge implements PwaBridge {
  _WebPwaBridge() {
    _listener = ((web.Event _) => _controller.add(null)).toJS;
    web.window.addEventListener('ctms-pwa', _listener);
  }

  final _controller = StreamController<void>.broadcast();
  late final JSFunction _listener;

  @override
  PwaSnapshot get snapshot {
    final api = _api;
    if (api == null) return const PwaSnapshot();
    final s = api.callMethod<JSObject?>('snapshot'.toJS);
    if (s == null) return const PwaSnapshot();
    return PwaSnapshot(
      installable: _flag(s, 'installable'),
      standalone: _flag(s, 'standalone'),
      iosSafari: _flag(s, 'iosSafari'),
      installed: _flag(s, 'installed'),
      updateReady: _flag(s, 'updateReady'),
      activatedElsewhere: _flag(s, 'activatedElsewhere'),
      swSupported: _flag(s, 'swSupported'),
    );
  }

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<InstallOutcome> promptInstall() async {
    final api = _api;
    if (api == null) return InstallOutcome.unavailable;
    try {
      final p = api.callMethod<JSPromise<JSString>>('promptInstall'.toJS);
      return switch ((await p.toDart).toDart) {
        'accepted' => InstallOutcome.accepted,
        'dismissed' => InstallOutcome.dismissed,
        _ => InstallOutcome.unavailable,
      };
    } catch (_) {
      return InstallOutcome.dismissed;
    }
  }

  @override
  void applyUpdate() => _api?.callMethod<JSAny?>('applyUpdate'.toJS);

  @override
  Future<int> clearCaches() async {
    final api = _api;
    if (api == null) return 0;
    try {
      final p = api.callMethod<JSPromise<JSNumber>>('clearCaches'.toJS);
      return (await p.toDart).toDartInt;
    } catch (_) {
      return 0;
    }
  }

  @override
  void dispose() {
    web.window.removeEventListener('ctms-pwa', _listener);
    _controller.close();
  }
}

PwaBridge createPwaBridge() => _WebPwaBridge();
