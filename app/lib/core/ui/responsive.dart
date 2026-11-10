import 'package:flutter/widgets.dart';

/// Window size classes from the web/PWA plan (section 4.2). This is the one
/// place that decides layout by width; screens never branch on `kIsWeb`.
enum WindowClass {
  /// Under 600 px: bottom navigation, single column.
  compact,

  /// 600-1023 px: navigation rail, single content column.
  medium,

  /// 1024-1439 px: navigation rail with a two-pane workspace.
  expanded,

  /// 1440 px and up: centred two-pane workspace, capped width.
  large;

  /// Navigation rail instead of a bottom bar.
  bool get usesRail => this != compact;

  /// Map and sidebar side by side.
  bool get isTwoPane => this == expanded || this == large;
}

class Breakpoints {
  const Breakpoints._();

  static const double medium = 600;
  static const double expanded = 1024;
  static const double large = 1440;

  /// Content width cap so a wide monitor does not stretch the workspace.
  static const double maxContentWidth = 1600;
}

WindowClass windowClassForWidth(double width) {
  if (width >= Breakpoints.large) return WindowClass.large;
  if (width >= Breakpoints.expanded) return WindowClass.expanded;
  if (width >= Breakpoints.medium) return WindowClass.medium;
  return WindowClass.compact;
}

extension ResponsiveContext on BuildContext {
  WindowClass get windowClass =>
      windowClassForWidth(MediaQuery.sizeOf(this).width);

  /// True when the OS asks for reduced motion.
  bool get reduceMotion => MediaQuery.disableAnimationsOf(this);
}

/// Duration that collapses to zero under reduced motion.
Duration motionDuration(BuildContext context, Duration normal) =>
    context.reduceMotion ? Duration.zero : normal;

/// Fixed-width digits so times and ETAs do not jitter as they change.
const List<FontFeature> tabularFigures = [FontFeature.tabularFigures()];

TextStyle tabular([TextStyle? base]) =>
    (base ?? const TextStyle()).copyWith(fontFeatures: tabularFigures);

/// Minimum touch target (dp).
const double minTouchTarget = 48;
