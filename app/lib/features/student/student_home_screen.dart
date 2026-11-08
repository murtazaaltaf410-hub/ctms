import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/connection_banner.dart';
import '../../privacy/app_config.dart';
import '../../privacy/consent.dart';
import '../../push/push_service.dart';
import '../../realtime/live_messages.dart';
import '../../realtime/live_providers.dart';
import 'student_providers.dart';

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen> {
  int _tab = 0;
  String? _routeId;
  String? _stopId;
  bool _listView = false;
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<ForegroundPush>? _pushSubscription;
  Position? _lastUploaded;
  bool _notificationsDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(liveBusesProvider.notifier).refetch();
    });
    _pushSubscription = ref.read(pushServiceProvider).foregroundMessages.listen(
      (message) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                [
                  message.title,
                  message.body,
                ].where((s) => s.isNotEmpty).join(': '),
              ),
            ),
          );
        }
      },
    );
    unawaited(_checkNotificationPermission());
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _pushSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<LiveMessage>>(liveMessagesProvider, (_, next) {
      final message = next.value;
      if (message is AnnouncementMessage && mounted) {
        ref.invalidate(announcementsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${message.urgent ? 'Urgent: ' : ''}${message.title}',
            ),
          ),
        );
      }
    });
    final titles = ['Live buses', 'Announcements', 'Nearby alerts', 'Profile'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: _listView ? 'Show map' : 'Show list',
              onPressed: () => setState(() => _listView = !_listView),
              icon: Icon(
                _listView ? Icons.map_outlined : Icons.format_list_bulleted,
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: switch (_tab) {
              0 => _LiveTab(
                listView: _listView,
                routeId: _routeId,
                stopId: _stopId,
                onRouteChanged: (id) => setState(() {
                  _routeId = id;
                  _stopId = null;
                }),
                onStopChanged: (id) => setState(() => _stopId = id),
                onShowList: () => setState(() => _listView = true),
              ),
              1 => const _AnnouncementsTab(),
              2 => _AlertsTab(
                onEnabled: _enableAlerts,
                notificationsDenied: _notificationsDenied,
              ),
              _ => _ProfileTab(onDelete: _deleteAccount),
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.directions_bus_outlined),
            selectedIcon: Icon(Icons.directions_bus),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            selectedIcon: Icon(Icons.campaign),
            label: 'Notices',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_none),
            selectedIcon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    switch (_tab) {
      case 0:
        await ref.read(liveBusesProvider.notifier).refetch();
        break;
      case 1:
        await ref.read(announcementsProvider.notifier).refresh();
        break;
      case 2:
        ref.invalidate(alertSettingsProvider);
        ref.invalidate(sentAlertsProvider);
        break;
    }
  }

  Future<void> _enableAlerts(bool enabled) async {
    try {
      if (enabled) {
        final consent = await ensureConsent(
          context,
          ref,
          ConsentKind.studentLocation,
        );
        if (!consent) return;
        final permission = await _locationPermission();
        if (permission == null) return;
        await _uploadCurrentLocation();
        _startLocationUpload(permission);
      } else {
        await _locationSubscription?.cancel();
        _locationSubscription = null;
      }
      await ref.read(alertSettingsProvider.notifier).setEnabled(enabled);
    } on ApiException catch (e) {
      _message(
        e.message ?? 'Nearby alerts could not be updated. Please try again.',
      );
    } on LocationServiceDisabledException {
      _message('Turn on location services to use nearby alerts.');
    } catch (_) {
      _message('Nearby alerts could not be updated. Please try again.');
    }
  }

  Future<void> _checkNotificationPermission() async {
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (mounted) {
        setState(
          () => _notificationsDenied =
              settings.authorizationStatus == AuthorizationStatus.denied,
        );
      }
    } catch (_) {
      // Firebase is optional during local development; do not block alerts UI.
    }
  }

  Future<LocationPermission?> _locationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _message('Turn on location services to use nearby alerts.');
      return null;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      _message(
        'Location permission is blocked. Allow it in Settings to enable alerts.',
      );
      await Geolocator.openAppSettings();
      return null;
    }
    if (permission == LocationPermission.denied) {
      _message('Location permission is needed for nearby alerts.');
      return null;
    }
    return permission;
  }

  Future<void> _uploadCurrentLocation() async {
    final position = await Geolocator.getCurrentPosition();
    await _upload(position);
  }

  void _startLocationUpload(LocationPermission permission) {
    _locationSubscription?.cancel();
    _locationSubscription = Geolocator.getPositionStream().listen((position) {
      final config = ref.read(appConfigProvider).value ?? AppConfig.fallback;
      if (_lastUploaded == null ||
          Geolocator.distanceBetween(
                _lastUploaded!.latitude,
                _lastUploaded!.longitude,
                position.latitude,
                position.longitude,
              ) >=
              config.studentMoveReportM) {
        unawaited(_upload(position));
      }
    });
    if (permission != LocationPermission.always) {
      _message(
        'Alerts refresh while this app is open. Allow background location for continuous alerts.',
      );
    }
  }

  Future<void> _upload(Position position) async {
    final config = ref.read(appConfigProvider).value ?? AppConfig.fallback;
    if (position.accuracy >= config.studentFixMaxAccuracyM) return;
    await ref
        .read(studentRepositoryProvider)
        .uploadLocation(
          lat: position.latitude,
          lng: position.longitude,
          accuracy: position.accuracy,
          recordedAt: position.timestamp,
        );
    _lastUploaded = position;
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account, saved alert settings, location, and alert history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(studentRepositoryProvider).deleteAccount();
      await ref.read(authControllerProvider.notifier).signOut();
    } on ApiException catch (e) {
      _message(
        e.message ??
            'Account deletion could not be completed. Please try again.',
      );
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

class _LiveTab extends ConsumerWidget {
  const _LiveTab({
    required this.listView,
    required this.routeId,
    required this.stopId,
    required this.onRouteChanged,
    required this.onStopChanged,
    required this.onShowList,
  });

  final bool listView;
  final String? routeId;
  final String? stopId;
  final ValueChanged<String?> onRouteChanged;
  final ValueChanged<String?> onStopChanged;
  final VoidCallback onShowList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(studentRoutesProvider);
    final buses = ref.watch(liveBusesProvider).values.toList();
    final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
    final selectedRoute = routeId ?? routes.value?.firstOrNull?.id;
    final visible = buses
        .where((bus) => selectedRoute == null || bus.routeId == selectedRoute)
        .toList();
    final detail = selectedRoute == null
        ? null
        : ref.watch(studentRouteProvider(selectedRoute));
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(studentRoutesProvider);
        await ref.read(liveBusesProvider.notifier).refetch();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          routes.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => _RetryCard(
              label: 'Routes could not load.',
              onRetry: () => ref.invalidate(studentRoutesProvider),
            ),
            data: (items) => DropdownButtonFormField<String>(
              initialValue: selectedRoute,
              decoration: const InputDecoration(labelText: 'Route'),
              items: items
                  .map(
                    (route) => DropdownMenuItem(
                      value: route.id,
                      child: Text(route.name),
                    ),
                  )
                  .toList(),
              onChanged: onRouteChanged,
            ),
          ),
          const SizedBox(height: 12),
          if (detail != null)
            detail.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => _RetryCard(
                label: 'Stops could not load.',
                onRetry: () =>
                    ref.invalidate(studentRouteProvider(selectedRoute!)),
              ),
              data: (route) => _StopPicker(
                route: route,
                stopId: stopId,
                onChanged: onStopChanged,
              ),
            ),
          const SizedBox(height: 16),
          if (!listView && visible.isNotEmpty)
            _BusMap(buses: visible, route: detail?.value)
          else
            _BusList(buses: visible, config: config),
          if (!listView)
            TextButton.icon(
              onPressed: onShowList,
              icon: const Icon(Icons.format_list_bulleted),
              label: const Text('Map unavailable? Show bus list'),
            ),
          if (stopId != null)
            _EtaCard(stopId: stopId!, cap: config.etaDisplayCap),
        ],
      ),
    );
  }
}

class _StopPicker extends StatelessWidget {
  const _StopPicker({
    required this.route,
    required this.stopId,
    required this.onChanged,
  });
  final RouteDetail route;
  final String? stopId;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: stopId,
    decoration: const InputDecoration(labelText: 'Stop for ETA'),
    hint: const Text('Choose a stop'),
    items: route.stops
        .map(
          (stop) => DropdownMenuItem(
            value: stop.id,
            child: Text('${stop.sequence}. ${stop.name}'),
          ),
        )
        .toList(),
    onChanged: onChanged,
  );
}

class _BusMap extends StatelessWidget {
  const _BusMap({required this.buses, required this.route});
  final List<LiveBus> buses;
  final RouteDetail? route;
  @override
  Widget build(BuildContext context) {
    final center = LatLng(buses.first.lat, buses.first.lng);
    return SizedBox(
      height: 300,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: center, zoom: 14),
          markers: {
            for (final bus in buses)
              Marker(
                markerId: MarkerId(bus.busId),
                position: LatLng(bus.lat, bus.lng),
                infoWindow: InfoWindow(
                  title: bus.label,
                  snippet: '${bus.routeName} · ${_statusText(bus.status)}',
                ),
              ),
            for (final stop in route?.stops ?? <Stop>[])
              Marker(
                markerId: MarkerId('stop-${stop.id}'),
                position: LatLng(stop.lat, stop.lng),
                infoWindow: InfoWindow(title: stop.name),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure,
                ),
              ),
          },
          polylines: route?.polyline == null
              ? const {}
              : {
                  Polyline(
                    polylineId: const PolylineId('route'),
                    points: _decodePolyline(route!.polyline!),
                    color: AppTheme.seed,
                    width: 5,
                  ),
                },
          myLocationButtonEnabled: false,
        ),
      ),
    );
  }
}

class _BusList extends StatelessWidget {
  const _BusList({required this.buses, required this.config});
  final List<LiveBus> buses;
  final AppConfig config;
  @override
  Widget build(BuildContext context) {
    if (buses.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('No buses are running on this route.')),
      );
    }
    final now = DateTime.now().toUtc();
    return Column(
      children: buses.map((bus) {
        final state = bus.stateAt(
          now,
          staleAfter: config.staleAfter,
          offlineAfter: config.offlineAfter,
        );
        return Card(
          child: ListTile(
            leading: Icon(Icons.directions_bus, color: _stateColor(state)),
            title: Text(bus.label),
            subtitle: Text(
              '${bus.routeName}\n${_statusText(bus.status)}${bus.note == null ? '' : ': ${bus.note}'}',
            ),
            isThreeLine: true,
            trailing: Text(_stateText(state), textAlign: TextAlign.end),
          ),
        );
      }).toList(),
    );
  }
}

class _EtaCard extends ConsumerWidget {
  const _EtaCard({required this.stopId, required this.cap});
  final String stopId;
  final Duration cap;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(stopEtaProvider(stopId))
      .when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => _RetryCard(
          label: 'ETA could not load.',
          onRetry: () => ref.invalidate(stopEtaProvider(stopId)),
        ),
        data: (eta) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Next buses',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (eta.etas.isEmpty)
                  Text(
                    eta.nextScheduled == null
                        ? 'No active bus is approaching this stop.'
                        : 'Next scheduled departure: ${_clock(eta.nextScheduled!)}',
                  ),
                ...eta.etas.map(
                  (bus) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(bus.label),
                    subtitle: Text(
                      '${_statusText(bus.status)}${bus.note == null ? '' : ': ${bus.note}'}',
                    ),
                    trailing: Text(_etaText(bus, cap)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _AnnouncementsTab extends ConsumerWidget {
  const _AnnouncementsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(announcementsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _RetryCard(
          label: 'Announcements could not load.',
          onRetry: () => ref.read(announcementsProvider.notifier).refresh(),
        ),
        data: (state) => RefreshIndicator(
          onRefresh: () => ref.read(announcementsProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (state.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(child: Text('No announcements yet.')),
                ),
              ...state.items.map(
                (item) => Card(
                  child: ListTile(
                    title: Text(item.title),
                    subtitle: Text('${item.body}\n${_clock(item.createdAt)}'),
                    isThreeLine: true,
                    leading: item.urgent
                        ? const Icon(
                            Icons.priority_high,
                            color: AppTheme.breakdown,
                          )
                        : const Icon(Icons.campaign_outlined),
                  ),
                ),
              ),
              if (state.hasMore)
                OutlinedButton(
                  onPressed: () =>
                      ref.read(announcementsProvider.notifier).loadMore(),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      );
}

class _AlertsTab extends ConsumerWidget {
  const _AlertsTab({
    required this.onEnabled,
    required this.notificationsDenied,
  });
  final ValueChanged<bool> onEnabled;
  final bool notificationsDenied;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(alertSettingsProvider);
    final alerts = ref.watch(sentAlertsProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (notificationsDenied)
          const Card(
            child: ListTile(
              leading: Icon(Icons.notifications_off),
              title: Text('Notifications are blocked'),
              subtitle: Text(
                'Allow notifications in device Settings to receive nearby-bus alerts.',
              ),
            ),
          ),
        settings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => _RetryCard(
            label: 'Alert settings could not load.',
            onRetry: () => ref.invalidate(alertSettingsProvider),
          ),
          data: (value) => Card(
            child: SwitchListTile(
              title: const Text('Alert me when a bus is near'),
              subtitle: const Text(
                'Uses your location to send nearby-bus alerts.',
              ),
              value: value.enabled,
              onChanged: onEnabled,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Recent alerts',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        alerts.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _RetryCard(
            label: 'Alert history could not load.',
            onRetry: () => ref.invalidate(sentAlertsProvider),
          ),
          data: (items) => items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No nearby-bus alerts have been sent.'),
                )
              : Column(
                  children: items
                      .map(
                        (alert) => ListTile(
                          leading: const Icon(Icons.directions_bus),
                          title: Text(alert.busLabel),
                          subtitle: Text(
                            '${alert.routeName} · ${_clock(alert.sentAt)}',
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab({required this.onDelete});
  final Future<void> Function() onDelete;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_circle),
            title: Text(user?.name ?? ''),
            subtitle: Text(user?.email ?? 'Student account'),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_forever, color: AppTheme.breakdown),
          label: const Text(
            'Delete account',
            style: TextStyle(color: AppTheme.breakdown),
          ),
        ),
      ],
    );
  }
}

class _RetryCard extends StatelessWidget {
  const _RetryCard({required this.label, required this.onRetry});
  final String label;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

List<LatLng> _decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  while (index < encoded.length) {
    int decode() {
      var result = 0;
      var shift = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);
      return result & 1 != 0 ? ~(result >> 1) : result >> 1;
    }

    lat += decode();
    lng += decode();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

Color _stateColor(BusState state) => switch (state) {
  BusState.live => AppTheme.onTime,
  BusState.stopped => AppTheme.delayed,
  BusState.stale || BusState.offline => AppTheme.stale,
};
String _stateText(BusState state) => switch (state) {
  BusState.live => 'Live',
  BusState.stopped => 'Stopped',
  BusState.stale => 'Last seen',
  BusState.offline => 'Offline',
};
String _statusText(String status) => switch (status) {
  'on_time' => 'On time',
  'delayed' => 'Delayed',
  'breakdown' => 'Breakdown',
  _ => status,
};
String _etaText(BusEta eta, Duration cap) {
  if (eta.passed) return 'Passed';
  if (eta.capped) return '${cap.inMinutes}+ min';
  final seconds = eta.etaSeconds;
  return seconds == null
      ? 'No ETA'
      : seconds < 60
      ? '<1 min'
      : '${(seconds / 60).ceil()} min';
}

String _clock(DateTime time) =>
    DateFormat.yMMMd().add_jm().format(time.toLocal());
