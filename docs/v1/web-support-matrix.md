# Web/PWA support matrix and privacy wording (ADR-11, PROPOSED)

| Client | Student | Admin | Driver | Notes |
|---|---|---|---|---|
| Android app | Full | Full | Full (only tracking client) | Regression baseline. |
| Chrome / Edge (Android, desktop), tab or installed | Supported | Supported (desktop-first) | Blocked: Android app required | Foreground location; Web Push if enabled. |
| Firefox (Android, desktop) | Supported, no Chrome-only promises | Supported | Blocked | No install prompt; Push capability-checked. |
| Safari macOS | Supported | Supported | Blocked | Install via Dock optional. |
| iPhone/iPad Safari | Supported | Mobile fallback | Blocked | Install via Add to Home Screen. |
| iPhone/iPad Home-Screen PWA | Supported | Mobile fallback | Blocked | Web Push only after install and a direct tap; never implies background location. |
| Apple App Store | Out of scope | | | |

Minimum: current and previous major version of each browser. Anything older sees an "unsupported browser" shell.

## Privacy wording (location prompt, shown before the browser permission)
"CTMS uses your location only while this page is open, to show your position relative to buses and stops and to alert you when a bus is near. Your latest position is kept briefly, is not visible to administrators or drivers, and is deleted when you leave the page for long or delete your account. You can turn this off at any time."

## Hidden / closed behaviour (user-visible)
Hidden tab: monitoring is shown as paused. Closed PWA: no location collection. Push may announce bus events but is not a proximity guarantee.
