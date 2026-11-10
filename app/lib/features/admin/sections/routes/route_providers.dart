import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../realtime/live_providers.dart';
import '../../admin_models.dart';
import '../../admin_providers.dart';
import 'route_logic.dart';

/// One route with its polyline and ordered stops (`GET /admin/routes/{id}`).
final adminRouteDetailProvider = FutureProvider.family<AdminRoute, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).route(id),
);

/// A create that failed without the server keeping a draft (offline, 5xx).
class PendingRouteDraftNotifier extends Notifier<PendingRouteDraft?> {
  @override
  PendingRouteDraft? build() => null;

  void keep(PendingRouteDraft draft) => state = draft;
  void clear() => state = null;
}

final pendingRouteDraftProvider =
    NotifierProvider<PendingRouteDraftNotifier, PendingRouteDraft?>(
      PendingRouteDraftNotifier.new,
    );

/// True while a bus is on an active trip on [routeId] (live feed).
final routeHasLiveTripProvider = Provider.family<bool, String>((ref, routeId) {
  final buses = ref.watch(liveBusesProvider);
  return buses.values.any((b) => b.routeId == routeId);
});
