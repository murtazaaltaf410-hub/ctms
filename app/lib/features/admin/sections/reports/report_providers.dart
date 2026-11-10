import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_models.dart';
import '../../admin_providers.dart';
import 'file_export.dart' as io;
import 'file_export_types.dart';

typedef ReportRange = ({String? from, String? to});

/// Trip history for a date range (server side); other filters run locally.
final reportTripsProvider =
    FutureProvider.family<List<TripReport>, ReportRange>(
      (ref, range) => ref
          .watch(adminRepositoryProvider)
          .trips(from: range.from, to: range.to),
    );

/// Recorded bus positions of one trip (never student positions).
final reportTripPathProvider = FutureProvider.family<TripPath, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).tripPath(id),
);

/// Tests replace this to capture the exported file.
final textFileSaverProvider = Provider<TextFileSaver>((ref) => io.saveTextFile);
