import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/ui/polyline.dart';
import '../../core/ui/maps/transit_map.dart';
import '../../core/ui/maps/transit_map_models.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/connection_banner.dart';
import '../../core/ui/widgets/ctms_nav_bar.dart';
import '../../core/ui/widgets/last_updated_text.dart';
import '../../core/ui/widgets/live_state_pill.dart';
import '../../core/ui/widgets/section_label.dart';
import '../../privacy/app_config.dart';
import '../../privacy/consent.dart';
import '../../push/push_service.dart';
import '../../realtime/live_messages.dart';
import '../../realtime/live_providers.dart';
import 'journey_push.dart';
import 'pickup_screen.dart';
import 'registration_providers.dart';
import 'student_providers.dart';

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen> {
  int _tab = 0;
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
        if (isJourneyStartedPush(message)) {
          if (mounted) {
            showJourneyStartedBanner(ScaffoldMessenger.of(context));
            unawaited(ref.read(liveBusesProvider.notifier).refetch());
          }
          return;
        }
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
      appBar: _tab == 0
          ? null
          : AppBar(
              title: Text(titles[_tab]),
              actions: [
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
                stopId: _stopId,
                onStopChanged: (id) => setState(() => _stopId = id),
                onToggleList: () => setState(() => _listView = !_listView),
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
      bottomNavigationBar: CtmsNavBar(
        selectedIndex: _tab,
        onSelected: (value) => setState(() => _tab = value),
        items: const [
          CtmsNavItem(
            icon: Icons.directions_bus_outlined,
            selectedIcon: Icons.directions_bus,
            label: 'Live',
          ),
          CtmsNavItem(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign,
            label: 'Notices',
          ),
          CtmsNavItem(
            icon: Icons.notifications_none,
            selectedIcon: Icons.notifications,
            label: 'Alerts',
          ),
          CtmsNavItem(
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
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
    required this.stopId,
    required this.onStopChanged,
    required this.onToggleList,
  });

  final bool listView;
  final String? stopId;
  final ValueChanged<String?> onStopChanged;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Students only ever see the route they were approved for; the server
    // filters the buses too, this keeps the screen right if a message slips by.
    final registration = ref.watch(registrationProvider);
    final profile = registration.value;
    final buses = ref.watch(liveBusesProvider).values.toList();
    final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
    final selectedRoute = profile?.routeId;
    final visible = buses
        .where(
          (bus) =>
              bus.routeId == selectedRoute ||
              (selectedRoute == null && profile == null),
        )
        .toList();
    final detail = selectedRoute == null
        ? null
        : ref.watch(studentRouteProvider(selectedRoute));
    final route = detail?.value;
    Stop? stop;
    if (route != null && stopId != null) {
      for (final s in route.stops) {
        if (s.id == stopId) stop = s;
      }
    }

    Future<void> refresh() async {
      ref.invalidate(registrationProvider);
      await ref.read(liveBusesProvider.notifier).refetch();
    }

    final showMap = !listView && visible.isNotEmpty;
    final main = showMap
        ? LayoutBuilder(
            builder: (context, box) => _BusMap(
              buses: visible,
              route: route,
              height: box.maxHeight.isFinite ? box.maxHeight : 300,
            ),
          )
        : RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [_BusList(buses: visible, config: config)],
            ),
          );
    final panel = _JourneyPanel(
      profile: profile,
      visible: visible,
      registrationLoading: registration.isLoading,
      detail: detail,
      stopId: stopId,
      stop: stop,
      config: config,
      onRetryRoute: () => ref.invalidate(studentRouteProvider(selectedRoute!)),
    );
    final header = _LiveHeader(
      stopName: stop?.name,
      route: route,
      listView: listView,
      onStopChanged: onStopChanged,
      onToggleList: onToggleList,
      onRefresh: refresh,
    );

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 600) {
          return Column(
            children: [
              header,
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: main),
                    SizedBox(
                      width: 400,
                      child: SingleChildScrollView(child: panel),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            header,
            Expanded(child: main),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.6),
              child: SingleChildScrollView(child: panel),
            ),
          ],
        );
      },
    );
  }
}

/// Eyebrow + serif title on the left, stop name + target button on the right.
class _LiveHeader extends StatelessWidget {
  const _LiveHeader({
    required this.stopName,
    required this.route,
    required this.listView,
    required this.onStopChanged,
    required this.onToggleList,
    required this.onRefresh,
  });

  final String? stopName;
  final RouteDetail? route;
  final bool listView;
  final ValueChanged<String?> onStopChanged;
  final VoidCallback onToggleList;
  final VoidCallback onRefresh;

  Future<void> _pickStop(BuildContext context) async {
    final stops = route?.stops;
    if (stops == null || stops.isEmpty) return;
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SectionLabel('Stop for ETA'),
            ),
            for (final stop in stops)
              ListTile(
                title: Text('${stop.sequence}. ${stop.name}'),
                onTap: () => Navigator.pop(context, stop.id),
              ),
          ],
        ),
      ),
    );
    if (id != null) onStopChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      color: c.bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('North Campus · Live'),
                    const SizedBox(height: 6),
                    Text(
                      'Your next bus',
                      style: CtmsText.headline(context, 34),
                    ),
                  ],
                ),
              ),
              if (stopName != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 14),
                    child: Text(
                      stopName!,
                      key: const Key('student-selected-stop'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtmsText.ui(context, 14, FontWeight.w500),
                    ),
                  ),
                ),
              IconButton(
                tooltip: listView ? 'Show map' : 'Show list',
                onPressed: onToggleList,
                color: c.muted,
                icon: Icon(
                  listView ? Icons.map_outlined : Icons.format_list_bulleted,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: onRefresh,
                color: c.muted,
                icon: const Icon(Icons.refresh),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Material(
                  color: c.surface,
                  shape: CircleBorder(side: BorderSide(color: c.border)),
                  child: IconButton(
                    key: const Key('student-stop-button'),
                    tooltip: 'Choose your stop',
                    onPressed: route == null ? null : () => _pickStop(context),
                    color: c.olive,
                    iconSize: 26,
                    icon: const Icon(Icons.my_location),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom journey panel: route/bus, live state, ETA card, refresh row, pickup.
class _JourneyPanel extends ConsumerWidget {
  const _JourneyPanel({
    required this.profile,
    required this.visible,
    required this.registrationLoading,
    required this.detail,
    required this.stopId,
    required this.stop,
    required this.config,
    required this.onRetryRoute,
  });

  final StudentRegistration? profile;
  final List<LiveBus> visible;
  final bool registrationLoading;
  final AsyncValue<RouteDetail>? detail;
  final String? stopId;
  final Stop? stop;
  final AppConfig config;
  final VoidCallback onRetryRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ctms;
    final bus = visible.isEmpty ? null : visible.first;
    final eta = stopId == null ? null : ref.watch(stopEtaProvider(stopId!));
    BusEta? primary;
    for (final e in eta?.value?.etas ?? const <BusEta>[]) {
      if (!e.passed && primary == null) primary = e;
    }
    final km = primary?.distanceM;
    final busLabel = bus?.label ?? profile?.busLabel;
    final routeName = bus?.routeName ?? profile?.routeName;
    final title = [busLabel, routeName].whereType<String>().join(' · ');
    final state = bus?.stateAt(
      DateTime.now().toUtc(),
      staleAfter: config.staleAfter,
      offlineAfter: config.offlineAfter,
    );

    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (profile != null)
              Row(
                key: const Key('student-route-card'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.isEmpty ? 'Your route' : title,
                          style: CtmsText.ui(context, 20, FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          km != null
                              ? '${(km / 1000).toStringAsFixed(1)} km away'
                              : profile!.busLabel == null
                              ? 'Your route'
                              : 'Your bus: ${profile!.busLabel}',
                          style: CtmsText.ui(
                            context,
                            15,
                          ).copyWith(color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  if (state != null) ...[
                    const SizedBox(width: 12),
                    LiveStatePill(
                      label: _stateText(state),
                      tone: switch (state) {
                        BusState.live => PillTone.live,
                        BusState.stopped => PillTone.delayed,
                        _ => PillTone.stale,
                      },
                    ),
                  ],
                ],
              )
            else if (registrationLoading)
              const LinearProgressIndicator(),
            if (detail != null)
              detail!.when(
                loading: () => const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => _RetryCard(
                  label: 'Stops could not load.',
                  onRetry: onRetryRoute,
                ),
                data: (_) => const SizedBox.shrink(),
              ),
            const SizedBox(height: 16),
            if (stopId != null)
              _EtaCard(
                stopId: stopId!,
                stopName: stop?.name,
                cap: config.etaDisplayCap,
              )
            else if (detail?.hasValue ?? false)
              Text(
                'Choose your stop with the target button to see when the bus arrives.',
                style: CtmsText.ui(context, 14).copyWith(color: c.muted),
              ),
            if (bus != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.sync, size: 18, color: c.muted),
                  const SizedBox(width: 8),
                  LastUpdatedText(
                    bus.lastFixAt,
                    staleAfter: config.staleAfter,
                    offlineAfter: config.offlineAfter,
                    style: CtmsText.ui(context, 14).copyWith(color: c.muted),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _PickupCard(route: detail?.value),
          ],
        ),
      ),
    );
  }
}

/// "Request a pickup": a temporary pin the driver sees as a waiting student.
class _PickupCard extends ConsumerWidget {
  const _PickupCard({required this.route});

  final RouteDetail? route;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Pickup pickup,
  ) async {
    try {
      await ref.read(studentRepositoryProvider).cancelPickup(pickup.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not cancel. Try again.')),
        );
      }
    } finally {
      ref.invalidate(myPickupProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pickup = ref.watch(myPickupProvider).value;
    if (pickup != null) {
      final minutes = pickup.expiresAt.difference(DateTime.now()).inMinutes;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.place),
          title: Text('Pickup requested · ${pickup.direction.label}'),
          subtitle: Text(
            [
              pickup.routeName,
              if (pickup.label != null) pickup.label!,
              if (minutes > 0) 'expires in $minutes min',
            ].join(' · '),
          ),
          trailing: TextButton(
            onPressed: () => _cancel(context, ref, pickup),
            child: const Text('Cancel'),
          ),
        ),
      );
    }
    final current = route;
    return OutlinedButton.icon(
      onPressed: current == null
          ? null
          : () async {
              final requested = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => PickupScreen(route: current)),
              );
              if (requested == true && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Pickup requested. The driver will be told.'),
                  ),
                );
              }
            },
      icon: const Icon(Icons.place_outlined),
      label: const Text('Request a pickup'),
    );
  }
}

class _BusMap extends StatelessWidget {
  const _BusMap({
    required this.buses,
    required this.route,
    required this.height,
  });
  final List<LiveBus> buses;
  final RouteDetail? route;
  final double height;
  @override
  Widget build(BuildContext context) {
    final selectedRoute = route;
    return TransitMapPreview(
      title: 'Live bus map',
      height: height,
      data: TransitMapData(
        buses: [
          for (final bus in buses)
            TransitMapBus(
              id: bus.busId,
              label: bus.label,
              position: MapCoordinate(bus.lat, bus.lng),
              heading: bus.heading,
              detail:
                  '${bus.routeName} · ${bus.direction.label} · ${_statusText(bus.status)}',
            ),
        ],
        routes: selectedRoute == null
            ? const []
            : [
                TransitMapRoute(
                  id: selectedRoute.id,
                  name: selectedRoute.name,
                  points: selectedRoute.polyline == null
                      ? const []
                      : [
                          for (final point in decodePolyline(
                            selectedRoute.polyline!,
                          ))
                            MapCoordinate(point.latitude, point.longitude),
                        ],
                  stops: [
                    for (final stop in selectedRoute.stops)
                      TransitMapStop(
                        id: stop.id,
                        label: stop.name,
                        position: MapCoordinate(stop.lat, stop.lng),
                        routeId: selectedRoute.id,
                      ),
                  ],
                  color: context.ctms.blue,
                ),
              ],
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
        child: Center(
          child: Text(
            'No bus is running on your route right now',
            textAlign: TextAlign.center,
          ),
        ),
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
              '${bus.routeName} · ${bus.direction.label}\n${_statusText(bus.status)}${bus.note == null ? '' : ': ${bus.note}'}',
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
  const _EtaCard({
    required this.stopId,
    required this.stopName,
    required this.cap,
  });
  final String stopId;
  final String? stopName;
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
        data: (eta) {
          final c = context.ctms;
          final upcoming = eta.etas.where((e) => !e.passed).toList();
          final first = upcoming.isEmpty ? null : upcoming.first;
          final seconds = first?.etaSeconds;
          final arrival = first != null && !first.capped && seconds != null
              ? DateFormat.Hm().format(
                  DateTime.now().add(Duration(seconds: seconds)),
                )
              : null;
          final delayed = first?.status == 'delayed';
          final broken = first?.status == 'breakdown';
          return Container(
            key: const Key('student-eta-card'),
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _etaCardBg,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ['Your stop', ?stopName].join(' · ').toUpperCase(),
                  style: CtmsText.ui(
                    context,
                    13,
                    FontWeight.w600,
                  ).copyWith(letterSpacing: 0.6, color: _etaCardMuted),
                ),
                const SizedBox(height: 10),
                if (first == null)
                  Text(
                    eta.nextScheduled == null
                        ? 'No active bus is approaching this stop.'
                        : 'Next scheduled departure: ${_clock(eta.nextScheduled!)}',
                    style: CtmsText.ui(context, 18).copyWith(color: _etaCardFg),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          _arrivingText(first, cap),
                          style: CtmsText.ui(
                            context,
                            26,
                          ).copyWith(color: _etaCardFg),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (arrival != null)
                            Text(
                              arrival,
                              style: CtmsText.data(
                                context,
                                28,
                                FontWeight.w600,
                              ).copyWith(color: c.gold),
                            ),
                          Text(
                            _statusText(first.status).toUpperCase(),
                            style: CtmsText.ui(context, 13, FontWeight.w600)
                                .copyWith(
                                  color: broken
                                      ? const Color(0xFFFFB4AB)
                                      : delayed
                                      ? c.gold
                                      : _etaCardMuted,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                if (first?.note != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    first!.note!,
                    style: CtmsText.ui(
                      context,
                      14,
                    ).copyWith(color: _etaCardMuted),
                  ),
                ],
                for (final other in upcoming.skip(1)) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          other.label,
                          style: CtmsText.ui(
                            context,
                            14,
                          ).copyWith(color: _etaCardMuted),
                        ),
                      ),
                      Text(
                        _etaText(other, cap),
                        style: CtmsText.data(
                          context,
                          14,
                        ).copyWith(color: _etaCardFg),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      );
}

// The ETA card is dark in both themes (frame H7VF2).
const _etaCardBg = Color(0xFF253426);
const _etaCardFg = Color(0xFFF4F7EC);
const _etaCardMuted = Color(0xFFC9D8B4);

String _arrivingText(BusEta eta, Duration cap) {
  final seconds = eta.etaSeconds;
  if (eta.capped) return 'Arriving in ${cap.inMinutes}+ min';
  if (seconds == null) return 'No ETA yet';
  if (seconds < 60) return 'Arriving in <1 min';
  return 'Arriving in ${(seconds / 60).ceil()} min';
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
    final profile = ref.watch(registrationProvider).value;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_circle),
            title: Text(profile?.fullName ?? user?.name ?? ''),
            subtitle: Text(user?.email ?? 'Student account'),
          ),
        ),
        if (profile != null)
          Card(
            key: const Key('profile-assignment'),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.directions_bus),
                  title: const Text('Assigned bus'),
                  subtitle: Text(profile.busLabel ?? 'Not assigned yet'),
                ),
                ListTile(
                  leading: const Icon(Icons.route),
                  title: const Text('Route'),
                  subtitle: Text(profile.routeName ?? 'Not set'),
                ),
                if (profile.department != null)
                  ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: const Text('Department'),
                    subtitle: Text(profile.department!),
                  ),
                if (profile.phone != null)
                  ListTile(
                    leading: const Icon(Icons.phone_outlined),
                    title: const Text('Phone'),
                    subtitle: Text(profile.phone!),
                  ),
              ],
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
