import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../theme.dart';
import 'transit_map_models.dart';

const _white = Color(0xFFFFFFFF);

Color toneColor(TransitMapTone tone, bool dark) {
  final c = dark ? CtmsColors.dark : CtmsColors.light;
  return switch (tone) {
    TransitMapTone.live => c.olive,
    TransitMapTone.delayed => c.delayed,
    TransitMapTone.breakdown => c.breakdown,
    TransitMapTone.stale => c.stale,
  };
}

Future<Uint8List> _render(
  double logicalSize,
  double dpr,
  void Function(Canvas canvas) draw,
) async {
  final px = (logicalSize * dpr).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(px / logicalSize);
  draw(canvas);
  final image = await recorder.endRecording().toImage(px, px);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void _shadow(Canvas canvas, Offset center, double radius) => canvas.drawCircle(
  center + const Offset(0, 1.5),
  radius,
  Paint()
    ..color = const Color(0x40000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
);

/// The bus marker: white ring, state-coloured disc, bus glyph and (when the
/// heading is known) a notch that points the way the bus is travelling. The
/// bitmap is [BusMarkerSpec.logicalSize] logical px square, rendered at [dpr].
Future<Uint8List> renderBusMarker({
  required Color color,
  required bool withHeading,
  required double dpr,
}) => _render(BusMarkerSpec.logicalSize, dpr, (canvas) {
  const size = BusMarkerSpec.logicalSize;
  const center = Offset(size / 2, size / 2);
  _shadow(canvas, center, 15.5);
  if (withHeading) {
    final notch = Path()
      ..moveTo(size / 2, 0.5)
      ..lineTo(size / 2 + 5.5, 8)
      ..lineTo(size / 2 - 5.5, 8)
      ..close();
    canvas
      ..drawPath(
        notch,
        Paint()
          ..color = _white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round,
      )
      ..drawPath(notch, Paint()..color = color);
  }
  canvas
    ..drawCircle(center, 15.5, Paint()..color = _white)
    ..drawCircle(center, 12.5, Paint()..color = color);
  // Bus glyph.
  final body = RRect.fromRectAndRadius(
    Rect.fromCenter(center: center, width: 14, height: 15),
    const Radius.circular(3.2),
  );
  canvas
    ..drawRRect(body, Paint()..color = _white)
    ..drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center.translate(0, -3.4),
          width: 10.4,
          height: 4.6,
        ),
        const Radius.circular(1.4),
      ),
      Paint()..color = color,
    )
    ..drawCircle(center.translate(-3.6, 3.6), 1.3, Paint()..color = color)
    ..drawCircle(center.translate(3.6, 3.6), 1.3, Paint()..color = color);
});

/// Stop dot sizes (logical px).
double stopDotSize(TransitStopDot dot) => switch (dot) {
  TransitStopDot.origin || TransitStopDot.destination => 26,
  TransitStopDot.numbered => 22,
  TransitStopDot.plain => 16,
};

/// First stop: olive dot with a white core. Last stop: maroon dot with a white
/// square. Between: white dot with an olive rim and the stop number. Plain:
/// a small gold dot.
Future<Uint8List> renderStopDot({
  required TransitStopDot dot,
  required int number,
  required bool dark,
  required double dpr,
}) {
  final c = dark ? CtmsColors.dark : CtmsColors.light;
  final size = stopDotSize(dot);
  return _render(size, dpr, (canvas) {
    final center = Offset(size / 2, size / 2);
    _shadow(canvas, center, size / 2 - 1.5);
    switch (dot) {
      case TransitStopDot.origin:
        canvas
          ..drawCircle(center, size / 2 - 1, Paint()..color = _white)
          ..drawCircle(center, size / 2 - 4, Paint()..color = c.olive)
          ..drawCircle(center, 3.2, Paint()..color = _white);
      case TransitStopDot.destination:
        // The maroon token has no lighter dark variant; the white ring keeps it
        // legible on the dark map.
        canvas
          ..drawCircle(center, size / 2 - 1, Paint()..color = _white)
          ..drawCircle(
            center,
            size / 2 - 4,
            Paint()..color = CtmsColors.light.maroon,
          )
          ..drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: center, width: 6.4, height: 6.4),
              const Radius.circular(1.2),
            ),
            Paint()..color = _white,
          );
      case TransitStopDot.numbered:
        canvas
          ..drawCircle(center, size / 2 - 1, Paint()..color = c.olive)
          ..drawCircle(center, size / 2 - 3.2, Paint()..color = _white);
        final text = TextPainter(
          text: TextSpan(
            text: '$number',
            style: TextStyle(
              fontFamily: 'IBMPlexMono',
              fontSize: number > 9 ? 9 : 10.5,
              fontWeight: FontWeight.w700,
              color: dark ? const Color(0xFF14210A) : CtmsColors.light.olive,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
      case TransitStopDot.plain:
        canvas
          ..drawCircle(center, size / 2 - 1.5, Paint()..color = _white)
          ..drawCircle(center, size / 2 - 4, Paint()..color = c.gold);
    }
  });
}
