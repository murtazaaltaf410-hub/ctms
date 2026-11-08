import 'json.dart';

/// `GET /announcements` item (newest first, cursor pages).
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.urgent,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Announcement.fromJson(Json json) => Announcement(
    id: json['id'] as String,
    title: json['title'] as String,
    body: json['body'] as String,
    urgent: json['urgent'] as bool,
    createdAt: parseTime(json['created_at']),
    updatedAt: parseTime(json['updated_at']),
  );

  final String id;
  final String title;
  final String body;
  final bool urgent;
  final DateTime createdAt;
  final DateTime updatedAt;
}
