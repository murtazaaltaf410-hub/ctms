import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../auth/auth_controller.dart';
import '../../../core/models/models.dart';
import '../../../core/ui/theme.dart';
import '../../../core/ui/widgets/state_views.dart';
import '../student_providers.dart';
import '../widgets/photo_views.dart';

/// Logical width the card is designed at; it is scaled to the space it gets.
const _cardWidth = 320.0;

// The card is a printed pass, so it keeps the same paper, ink and brand
// colours in the light and dark themes (the QR code needs the contrast too).
const _maroon = Color(0xFF7C1E21);
const _olive = Color(0xFF5C7D1F);
const _gold = Color(0xFFD79B28);
const _paper = Color(0xFFFBFAF5);
const _ink = Color(0xFF213021);
const _muted = Color(0xFF687768);
const _rule = Color(0xFFDDE5D7);

/// The digital bus card: a portrait ID card with the University of Kashmir
/// header, passport photo, student and bus details, a QR code of the signed
/// payload and the "digitally signed" seal. Pure: give it the data.
class BusCardView extends StatelessWidget {
  const BusCardView({super.key, required this.card, this.photo});

  final BusCard card;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) {
    // A pass, not flowing text: keep its layout independent of the system
    // font scale. The full-screen view enlarges it instead.
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: Semantics(
        container: true,
        label:
            'Bus card of ${card.name}, card number ${card.cardNo}'
            '${card.validUntil == null ? '' : ', valid until ${card.validUntil}'}',
        child: SizedBox(
          width: _cardWidth,
          child: DecoratedBox(
            key: const Key('bus-card'),
            decoration: BoxDecoration(
              color: _paper,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _rule),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Header(),
                  _Identity(card: card, photo: photo),
                  _Details(card: card),
                  _QrBlock(payload: card.qrPayload),
                  _SealFooter(signature: card.signature),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          color: _maroon,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _gold, width: 1.5),
                ),
                child: const Icon(
                  Icons.directions_bus_filled_outlined,
                  size: 22,
                  color: _gold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'UNIVERSITY OF KASHMIR',
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Newsreader',
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'NORTH CAMPUS · BUS PASS',
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Geist',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: _gold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(height: 4, color: _gold),
      ],
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.card, required this.photo});

  final BusCard card;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _gold, width: 1.5),
              color: Colors.white,
            ),
            child: PhotoBox(
              key: const Key('bus-card-photo'),
              bytes: photo,
              width: 108,
              radius: 11,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            card.name,
            key: const Key('bus-card-name'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Newsreader',
              fontSize: 25,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: _ink,
            ),
          ),
          if (card.enrollmentNo != null) ...[
            const SizedBox(height: 6),
            Text(
              card.enrollmentNo!,
              style: const TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _olive,
                letterSpacing: 0.4,
              ),
            ),
          ],
          if (card.department != null) ...[
            const SizedBox(height: 2),
            Text(
              card.department!,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Geist',
                fontSize: 14,
                color: _muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.card});

  final BusCard card;

  @override
  Widget build(BuildContext context) {
    final bus = [card.busLabel, card.plate].whereType<String>().join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        children: [
          const Divider(color: _rule, height: 1),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Field('Route', card.routeName ?? 'Not assigned'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Field('Bus', bus.isEmpty ? 'Not assigned' : bus),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _Field('Card no.', card.cardNo, mono: true)),
              const SizedBox(width: 12),
              Expanded(
                child: _Field(
                  'Valid until',
                  card.validUntil ?? 'Not set',
                  mono: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.9,
            color: _muted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: mono ? 'IBMPlexMono' : 'Geist',
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: mono ? 13 : 14.5,
            fontWeight: FontWeight.w600,
            color: _ink,
          ),
        ),
      ],
    );
  }
}

class _QrBlock extends StatelessWidget {
  const _QrBlock({required this.payload});

  final String payload;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _rule),
            ),
            child: QrImageView(
              key: const Key('bus-card-qr'),
              data: payload,
              size: 132,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              semanticsLabel: 'QR code to verify this bus card',
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: _ink,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: _ink,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Show this code to the driver or the checking staff',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'Geist', fontSize: 12, color: _muted),
          ),
        ],
      ),
    );
  }
}

class _SealFooter extends StatelessWidget {
  const _SealFooter({required this.signature});

  final String signature;

  /// First and last characters, enough to compare two cards by eye.
  static String fingerprint(String signature) => signature.length <= 16
      ? signature
      : '${signature.substring(0, 8)}…${signature.substring(signature.length - 6)}';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('bus-card-seal'),
      width: double.infinity,
      color: _olive,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
            ),
            child: const Icon(Icons.verified, size: 22, color: _maroon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Digitally signed · Administration, University of Kashmir',
                  style: TextStyle(
                    fontFamily: 'Geist',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'SIG ${fingerprint(signature)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'IBMPlexMono',
                    fontSize: 11,
                    color: Color(0xFFE6ECD6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Loads the card and its photo for the signed-in student and shows it,
/// scaled to the available width. Tap opens [BusCardFullScreen].
class BusCardPanel extends ConsumerWidget {
  const BusCardPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ref.watch(busCardProvider);
    final userId = ref.watch(authControllerProvider).user?.id;
    return card.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Card(
        key: const Key('bus-card-error'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                Text(
                  ErrorView.describe(error),
                  textAlign: TextAlign.center,
                  style: CtmsText.ui(context, 15),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(busCardProvider),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (data) {
        final photo = userId == null
            ? null
            : ref.watch(studentPhotoProvider(userId)).value;
        return Center(
          child: Semantics(
            button: true,
            hint: 'Opens the card full screen',
            child: GestureDetector(
              key: const Key('bus-card-tap'),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => BusCardFullScreen(card: data, photo: photo),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: BusCardView(card: data, photo: photo),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The card as large as the screen allows, on a dark backdrop, for showing to
/// staff or taking a screenshot.
class BusCardFullScreen extends StatelessWidget {
  const BusCardFullScreen({super.key, required this.card, this.photo});

  final BusCard card;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121A14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121A14),
        foregroundColor: Colors.white,
        title: const Text('Bus card'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: FittedBox(
              key: const Key('bus-card-fullscreen'),
              fit: BoxFit.contain,
              child: BusCardView(card: card, photo: photo),
            ),
          ),
        ),
      ),
    );
  }
}
