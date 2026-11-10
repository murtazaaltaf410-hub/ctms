import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/theme.dart';
import 'passport_photo.dart';

/// Frames a picked image the way a passport photo is framed: a fixed 3:4
/// window with an oval face guide. The student drags and pinches the picture
/// under the window; "Use photo" crops exactly what the window shows, scales it
/// to 600 px high and pops the compressed JPEG. Pops null on cancel.
class PhotoFramingScreen extends ConsumerStatefulWidget {
  const PhotoFramingScreen({super.key, required this.photo});

  final PickedPhoto photo;

  @override
  ConsumerState<PhotoFramingScreen> createState() => _PhotoFramingScreenState();
}

class _PhotoFramingScreenState extends ConsumerState<PhotoFramingScreen> {
  final _controller = TransformationController();
  Size _viewport = Size.zero;
  Size _content = Size.zero;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Lay the picture out "cover" style in the window and centre it.
  void _layout(Size viewport) {
    if (viewport == _viewport) return;
    _viewport = viewport;
    final p = widget.photo;
    final scale = viewport.width / p.width > viewport.height / p.height
        ? viewport.width / p.width
        : viewport.height / p.height;
    _content = Size(p.width * scale, p.height * scale);
    _controller.value = Matrix4.translationValues(
      -(_content.width - viewport.width) / 2,
      -(_content.height - viewport.height) / 2,
      0,
    );
  }

  PhotoCrop _crop() {
    final topLeft = _controller.toScene(Offset.zero);
    final bottomRight = _controller.toScene(
      Offset(_viewport.width, _viewport.height),
    );
    return PhotoCrop(
      left: (topLeft.dx / _content.width).clamp(0, 1),
      top: (topLeft.dy / _content.height).clamp(0, 1),
      width: ((bottomRight.dx - topLeft.dx) / _content.width).clamp(0, 1),
      height: ((bottomRight.dy - topLeft.dy) / _content.height).clamp(0, 1),
    );
  }

  Future<void> _use() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List jpeg = await ref.read(photoProcessorProvider)(
        widget.photo.bytes,
        _crop(),
      );
      if (mounted) Navigator.pop(context, jpeg);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'That picture could not be used. Try another one.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Scaffold(
      appBar: AppBar(title: const Text('Frame your photo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Put your face inside the oval, looking straight ahead. Drag to '
              'move and pinch to zoom. Plain light background, no cap or '
              'sunglasses.',
              style: CtmsText.ui(context, 15).copyWith(color: c.muted),
            ),
            const SizedBox(height: 16),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: AspectRatio(
                  aspectRatio: PassportPhoto.aspect,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      _layout(box.biggest);
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: c.surface),
                            InteractiveViewer(
                              key: const Key('photo-viewer'),
                              transformationController: _controller,
                              constrained: false,
                              minScale: 1,
                              maxScale: 5,
                              boundaryMargin: EdgeInsets.zero,
                              child: SizedBox(
                                width: _content.width,
                                height: _content.height,
                                child: Image.memory(
                                  widget.photo.bytes,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                            const IgnorePointer(child: OvalGuide()),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('photo-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('photo-use'),
              onPressed: _busy ? null : _use,
              icon: const Icon(Icons.check),
              label: Text(_busy ? 'Preparing...' : 'Use photo'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('photo-cancel'),
              onPressed: _busy ? null : () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Choose another'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The oval face guide: everything outside the oval is dimmed. Drawn over the
/// 3:4 window; the oval sits a little above centre like a passport head.
class OvalGuide extends StatelessWidget {
  const OvalGuide({super.key});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _OvalGuidePainter(), size: Size.infinite);
}

class _OvalGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width * 0.64;
    final oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.45),
      width: width,
      height: width * 1.3,
    );
    final dim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addOval(oval),
    );
    canvas.drawPath(dim, Paint()..color = const Color(0x8C000000));
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xE6FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_OvalGuidePainter oldDelegate) => false;
}
