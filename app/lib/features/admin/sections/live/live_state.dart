import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/models.dart';
import '../../../../realtime/live_providers.dart';

/// Quick filters of the Live Operations fleet list.
enum LiveFilter {
  all('All'),
  delayed('Delayed'),
  breakdown('Breakdown'),
  stale('Stale or offline');

  const LiveFilter(this.label);
  final String label;
}

class LiveFilterNotifier extends Notifier<LiveFilter> {
  @override
  LiveFilter build() => LiveFilter.all;

  void set(LiveFilter value) => state = value;
}

final adminLiveFilterProvider =
    NotifierProvider<LiveFilterNotifier, LiveFilter>(LiveFilterNotifier.new);

/// Completes once `GET /buses/live` has been tried, so a deep link to a bus
/// does not flash "not found" before the first fetch lands. Failures are
/// swallowed: the last known data (possibly empty) is what we have.
final adminLiveLoadedProvider = FutureProvider<void>((ref) async {
  try {
    await ref.read(liveBusesProvider.notifier).refetch();
  } catch (_) {
    // Offline: the connection chip already says so.
  }
});

/// A live bus with its freshness worked out at a given moment.
class LiveFleetEntry {
  const LiveFleetEntry(this.bus, this.state);

  final LiveBus bus;

  /// Server state downgraded by the client clock (stale / offline).
  final BusState state;

  bool get isStaleOrOffline =>
      state == BusState.stale || state == BusState.offline;
}

/// Counts for the summary strip.
class LiveFleetSummary {
  const LiveFleetSummary({
    required this.active,
    required this.stale,
    required this.delayed,
    required this.breakdown,
  });

  final int active, stale, delayed, breakdown;
}

List<LiveFleetEntry> liveFleetEntries(
  Iterable<LiveBus> buses, {
  required DateTime now,
  required AppConfig config,
}) {
  final entries = [
    for (final bus in buses)
      LiveFleetEntry(
        bus,
        bus.stateAt(
          now,
          staleAfter: config.staleAfter,
          offlineAfter: config.offlineAfter,
        ),
      ),
  ]..sort((a, b) => a.bus.label.compareTo(b.bus.label));
  return entries;
}

LiveFleetSummary summarizeFleet(List<LiveFleetEntry> entries) =>
    LiveFleetSummary(
      active: entries.length,
      stale: entries.where((e) => e.isStaleOrOffline).length,
      delayed: entries.where((e) => e.bus.status == 'delayed').length,
      breakdown: entries.where((e) => e.bus.status == 'breakdown').length,
    );

bool liveFilterAccepts(LiveFilter filter, LiveFleetEntry e) => switch (filter) {
  LiveFilter.all => true,
  LiveFilter.delayed => e.bus.status == 'delayed',
  LiveFilter.breakdown => e.bus.status == 'breakdown',
  LiveFilter.stale => e.isStaleOrOffline,
};

/// Rebuilds [builder] every [every] with the current time, so freshness text
/// ("last seen 42 s ago") and stale/offline flip without a new bus message.
class LiveClock extends StatefulWidget {
  const LiveClock({
    super.key,
    required this.builder,
    this.every = const Duration(seconds: 10),
  });

  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration every;

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  Timer? _timer;
  DateTime _now = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() => _now = DateTime.now().toUtc());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
