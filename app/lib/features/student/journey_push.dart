import 'package:flutter/material.dart';

import '../../push/push_service.dart';

const journeyStartedText = 'Your bus has started its journey';

/// `journey_started` push: `{type, trip_id, bus_id, direction}`.
bool isJourneyStartedPush(ForegroundPush push) =>
    push.data?['type'] == 'journey_started';

void showJourneyStartedBanner(ScaffoldMessengerState messenger) {
  messenger.showSnackBar(
    const SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 8),
      content: Row(
        children: [
          Icon(Icons.directions_bus, color: Colors.white),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              journeyStartedText,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}
