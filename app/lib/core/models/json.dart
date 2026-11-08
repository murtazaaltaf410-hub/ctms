/// Small helpers for the hand-written `fromJson` factories (no codegen).
///
/// The API sends snake_case keys, UUIDs as strings and UTC ISO-8601 times.
typedef Json = Map<String, dynamic>;

DateTime parseTime(Object? value) => DateTime.parse(value as String).toUtc();

DateTime? parseTimeOrNull(Object? value) =>
    value == null ? null : parseTime(value);

double toDouble(Object? value) => (value as num).toDouble();

double? toDoubleOrNull(Object? value) => (value as num?)?.toDouble();

List<T> parseList<T>(Object? value, T Function(Json) fromJson) =>
    (value as List? ?? const [])
        .map((e) => fromJson(e as Json))
        .toList(growable: false);

/// A cursor page: `{"items": [...], "next_cursor": "..." | null}`.
class CursorPage<T> {
  const CursorPage({required this.items, required this.nextCursor});

  factory CursorPage.fromJson(Json json, T Function(Json) fromItem) =>
      CursorPage(
        items: parseList(json['items'], fromItem),
        nextCursor: json['next_cursor'] as String?,
      );

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}
