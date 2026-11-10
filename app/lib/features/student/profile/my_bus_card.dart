import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/theme.dart';
import '../../../core/ui/widgets/section_label.dart';
import '../student_providers.dart';
import '../widgets/photo_views.dart';

/// Opens a URL with the platform (the phone app for `tel:`). Replaceable in
/// tests; returns false when nothing could handle it.
typedef UrlOpener = Future<bool> Function(Uri uri);

final urlOpenerProvider = Provider<UrlOpener>((ref) => launchUrl);

/// "My bus & driver": the assigned bus, the driver's photo and name, and a
/// button that calls the driver. The driver's phone is shared with riders by
/// the server; their address and licence are not.
class MyBusCard extends ConsumerWidget {
  const MyBusCard({super.key});

  Future<void> _call(BuildContext context, WidgetRef ref, String phone) async {
    var opened = false;
    try {
      opened = await ref.read(urlOpenerProvider)(
        Uri(scheme: 'tel', path: phone),
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the phone app. Number: $phone')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ctms;
    final bus = ref.watch(myBusProvider);
    return Card(
      key: const Key('my-bus-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: bus.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => Row(
            children: [
              Expanded(
                child: Text(
                  'Your bus could not load.',
                  style: CtmsText.ui(context, 15),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => ref.invalidate(myBusProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (data) {
            if (data == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionLabel('My bus & driver'),
                  const SizedBox(height: 8),
                  Text(
                    'No bus is assigned to you yet.',
                    style: CtmsText.ui(context, 15).copyWith(color: c.muted),
                  ),
                ],
              );
            }
            final driver = data.driver;
            final phone = driver?.phone;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('My bus & driver'),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (driver != null) ...[
                      DriverPhotoImage(
                        key: const Key('my-bus-driver-photo'),
                        driverId: driver.id,
                        width: 72,
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data.label,
                            key: const Key('my-bus-label'),
                            style: CtmsText.ui(context, 20, FontWeight.w600),
                          ),
                          if (data.plate != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              data.plate!,
                              key: const Key('my-bus-plate'),
                              style: CtmsText.data(
                                context,
                                14,
                              ).copyWith(color: c.muted),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Text(
                            driver == null
                                ? 'No driver assigned yet'
                                : 'Driver',
                            style: CtmsText.ui(
                              context,
                              13,
                            ).copyWith(color: c.muted),
                          ),
                          if (driver != null)
                            Text(
                              driver.name,
                              key: const Key('my-bus-driver-name'),
                              style: CtmsText.ui(context, 16, FontWeight.w500),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (driver != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('call-driver'),
                    onPressed: phone == null || phone.isEmpty
                        ? null
                        : () => _call(context, ref, phone),
                    icon: const Icon(Icons.call),
                    label: Text(
                      phone == null || phone.isEmpty
                          ? 'No phone number'
                          : 'Call driver',
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
