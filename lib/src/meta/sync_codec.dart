import 'package:ds_sync_contract/ds_sync_contract.dart';

/// Conversion helpers that keep persisted sync metadata to primitive values.
///
/// Every field written to the metadata namespaces is a `String`, `int`, `num`
/// or `bool`. Nothing else survives both Hive and SQLite unchanged, and the
/// invariant "metadata behaves identically on both backends" depends on it.
///
/// Timestamps are stored as **Unix timestamps in microseconds** (`int`). That
/// makes the delta column a plain indexed integer on SQLite, so
/// `WHERE updated_at > ?` is a numeric comparison rather than a string one.
/// Microseconds, because that is the precision Firestore assigns server
/// timestamps with: an anchor stored with less precision would never compare
/// equal to the same, unchanged remote record again, and every pull would see
/// a change — or a conflict — that never happened.
abstract final class SyncCodec {
  /// Encodes a timestamp as Unix microseconds.
  static int? encodeTime(DateTime? value) => value?.microsecondsSinceEpoch;

  /// Values above this are microseconds, below it milliseconds.
  ///
  /// Earlier versions stored milliseconds. A millisecond value stays below
  /// 10^14 until the year 5138, a microsecond value is above it from 1973 on,
  /// so the magnitude tells the two apart without a format marker.
  static const int _microsecondThreshold = 100000000000000;

  /// Decodes a timestamp written by [encodeTime].
  ///
  /// Also reads the millisecond values earlier versions wrote, and accepts an
  /// ISO-8601 `String` or a `DateTime`, which is what some backends hand back
  /// for a server timestamp.
  static DateTime? decodeTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is int) {
      return value.abs() >= _microsecondThreshold
          ? DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  /// Encodes an opaque delta cursor for persistence.
  ///
  /// The cursor is produced by the adapter and never interpreted by the
  /// engine — but it has to survive a restart, so it must be a primitive the
  /// storage backend can hold. Supported: `String`, `int`, `DateTime`
  /// (persisted as Unix milliseconds), `null`.
  ///
  /// Throws [ArgumentError] for anything else, rather than silently persisting
  /// something a backend would mangle.
  static Map<String, dynamic>? encodeCursor(Object? cursor) {
    if (cursor == null) return null;
    if (cursor is String) return {'type': 'string', 'value': cursor};
    if (cursor is int) return {'type': 'int', 'value': cursor};
    if (cursor is DateTime) {
      return {'type': 'time', 'value': encodeTime(cursor)};
    }
    throw ArgumentError.value(
      cursor,
      'cursor',
      'Unsupported cursor type ${cursor.runtimeType}. A delta cursor must be '
          'a String, int or DateTime so it can be persisted identically on '
          'Hive and SQLite.',
    );
  }

  /// Decodes a cursor written by [encodeCursor].
  static Object? decodeCursor(Object? encoded) {
    if (encoded is! Map) return null;
    final type = encoded['type'];
    final value = encoded['value'];
    return switch (type) {
      'string' => value as String?,
      'int' => value as int?,
      'time' => decodeTime(value),
      _ => null,
    };
  }

  /// Encodes a [RemoteAnchor] into flat primitive fields.
  ///
  /// Returns `null` for an absent or empty anchor, so no useless keys are
  /// written.
  static Map<String, dynamic>? encodeAnchor(RemoteAnchor? anchor) {
    if (anchor == null || anchor.isEmpty) return null;
    return <String, dynamic>{
      if (anchor.version != null) 'version': anchor.version,
      if (anchor.updatedAt != null) 'updatedAt': encodeTime(anchor.updatedAt),
      if (anchor.contentHash != null) 'contentHash': anchor.contentHash,
    };
  }

  /// Decodes an anchor written by [encodeAnchor].
  static RemoteAnchor? decodeAnchor(Object? encoded) {
    if (encoded is! Map) return null;
    final anchor = RemoteAnchor(
      version: encoded['version'] as int?,
      updatedAt: decodeTime(encoded['updatedAt']),
      contentHash: encoded['contentHash'] as String?,
    );
    return anchor.isEmpty ? null : anchor;
  }

  /// Reads a `Map<String, dynamic>` back from storage.
  ///
  /// Backends may hand back a `Map<dynamic, dynamic>` (Hive does), so the
  /// entries are re-keyed rather than cast.
  static Map<String, dynamic>? asStringMap(Object? value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, dynamic v) => MapEntry(key.toString(), v));
    }
    return null;
  }
}
