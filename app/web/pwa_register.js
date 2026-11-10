/* Registers the CTMS service worker and captures install/update signals
 * before Dart boots (beforeinstallprompt can fire early). Dart reads the
 * small API on window.__ctmsPwa. Served no-cache. */
(function () {
  'use strict';
  var API = window.__ctmsPwa = {
    installEvent: null,
    waiting: null,
    installed: false,
    applying: false,
    activatedElsewhere: false,
    swSupported: 'serviceWorker' in navigator,
  };
  function emit() { window.dispatchEvent(new CustomEvent('ctms-pwa')); }

  function standalone() {
    return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
      navigator.standalone === true;
  }
  function iosSafari() {
    var ua = navigator.userAgent || '';
    var ios = /iPad|iPhone|iPod/.test(ua) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    return ios && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
  }

  API.snapshot = function () {
    return {
      installable: !!API.installEvent,
      standalone: standalone(),
      iosSafari: iosSafari(),
      installed: API.installed,
      updateReady: !!API.waiting,
      activatedElsewhere: API.activatedElsewhere,
      swSupported: API.swSupported,
    };
  };

  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    API.installEvent = e;
    emit();
  });
  window.addEventListener('appinstalled', function () {
    API.installEvent = null;
    API.installed = true;
    emit();
  });

  // Must be called from a user gesture handler.
  API.promptInstall = function () {
    var e = API.installEvent;
    if (!e) return Promise.resolve('unavailable');
    API.installEvent = null; // a prompt event is single-use
    return e.prompt().then(function () { return e.userChoice; })
      .then(function (c) { emit(); return c && c.outcome === 'accepted' ? 'accepted' : 'dismissed'; })
      .catch(function () { emit(); return 'dismissed'; });
  };

  // Only ever called from an explicit user action.
  API.applyUpdate = function () {
    if (!API.waiting) { window.location.reload(); return; }
    API.applying = true;
    API.waiting.postMessage({ type: 'SKIP_WAITING' });
  };

  API.clearCaches = function () {
    var n = 0;
    var done = Promise.resolve();
    if (window.caches && caches.keys) {
      done = caches.keys().then(function (names) {
        var mine = names.filter(function (k) { return k.indexOf('ctms-') === 0; });
        n = mine.length;
        return Promise.all(mine.map(function (k) { return caches.delete(k); }));
      });
    }
    return done.then(function () { return n; }, function () { return n; });
  };

  if (!API.swSupported) return;

  var lastCheck = 0;
  function check(reg) {
    var now = Date.now();
    if (now - lastCheck < 10 * 60 * 1000) return;
    lastCheck = now;
    reg.update().catch(function () {});
  }

  function track(reg) {
    function consider(w) {
      if (w && navigator.serviceWorker.controller) { API.waiting = w; emit(); }
    }
    consider(reg.waiting);
    reg.addEventListener('updatefound', function () {
      var w = reg.installing;
      if (!w) return;
      w.addEventListener('statechange', function () {
        if (w.state === 'installed') consider(w);
      });
    });
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') check(reg);
    });
    window.addEventListener('online', function () { check(reg); });
  }

  var hadController = !!navigator.serviceWorker.controller;
  navigator.serviceWorker.addEventListener('controllerchange', function () {
    if (!hadController) { hadController = true; return; } // first install claim
    if (API.applying) { window.location.reload(); return; }
    // Another tab applied an update: this tab runs old HTML against a new
    // worker/cache. Ask the user to reload at a safe point; never auto-reload.
    API.activatedElsewhere = true;
    emit();
  });

  window.addEventListener('load', function () {
    navigator.serviceWorker.register('ctms_sw.js', { scope: './', updateViaCache: 'none' })
      .then(track)
      .catch(function () { /* private mode / blocked: app works without it */ });
  });
})();
