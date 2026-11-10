import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'tab_coordinator_types.dart';

/// Web Locks API (`navigator.locks.request(name, {ifAvailable: true}, cb)`).
/// The lock is held until [release] resolves the promise returned by the
/// callback. Browsers without Web Locks fall back to "always leader" (the
/// server keeps only the latest fix, so a duplicate upload is harmless).
class _WebLockCoordinator implements TabCoordinator {
  static const _name = 'ctms-student-location-upload';

  Completer<JSAny?>? _held;

  @override
  bool get isLeader => _held != null;

  bool get _supported => (web.window.navigator as JSObject).has('locks');

  @override
  Future<bool> tryAcquire() async {
    if (_held != null) return true;
    if (!_supported) return true;
    final granted = Completer<bool>();
    final hold = Completer<JSAny?>();
    final callback = ((JSAny? lock) {
      if (lock == null) {
        granted.complete(false);
        return null;
      }
      granted.complete(true);
      return hold.future.toJS;
    }).toJS;
    web.window.navigator.locks.request(
      _name,
      web.LockOptions(ifAvailable: true),
      callback,
    );
    final ok = await granted.future;
    if (ok) _held = hold;
    return ok;
  }

  @override
  void release() {
    final h = _held;
    _held = null;
    if (h != null && !h.isCompleted) h.complete(null);
  }
}

TabCoordinator createTabCoordinator() => _WebLockCoordinator();
