import 'package:ds_sync_contract/ds_sync_contract.dart';

/// Namespaces and key construction for the sync metadata layer.
///
/// Metadata lives in its own reserved namespaces, strictly separate from user
/// payload — no `dirty` or `syncedAt` ever appears in a user document.
///
/// Keys are built from escaped segments so a collection or document id that
/// itself contains the separator cannot collide with another key. The scheme
/// is plain-string only, which keeps it identical on Hive and SQLite.
abstract final class SyncKeys {
  /// Namespace holding one entry per synced record.
  static const String metaNamespace = '__ds_sync__meta';

  /// Namespace holding one entry per synced collection (cursor state).
  static const String cursorNamespace = '__ds_sync__cursor';

  /// The reserved prefix. No user collection may start with it.
  static const String reservedPrefix = '__ds_sync__';

  /// The `userId` stored when running in [UserScope.single].
  ///
  /// A constant rather than `null` or an empty string, so `WHERE userId = ?`
  /// stays a plain indexed equality check on every backend.
  static const String singleUserId = '__single__';

  /// Separator between key segments.
  static const String separator = ':';

  /// Whether [collection] is one of the reserved sync namespaces.
  ///
  /// The engine refuses to sync such a collection — payload and metadata must
  /// never mix.
  static bool isReserved(String collection) =>
      collection.startsWith(reservedPrefix);

  /// Escapes a single key segment so separators inside it cannot be mistaken
  /// for structure.
  static String escapeSegment(String segment) =>
      segment.replaceAll(r'\', r'\\').replaceAll(separator, r'\:');

  /// Builds the per-record metadata key.
  ///
  /// In [UserScope.single] the user segment is omitted entirely — that mode
  /// carries zero key overhead.
  static String recordKey({
    required String userId,
    required String collection,
    required String docId,
    required UserScope scope,
  }) {
    final segments = <String>[
      if (scope == UserScope.perDevice) escapeSegment(userId),
      escapeSegment(collection),
      escapeSegment(docId),
    ];
    return segments.join(separator);
  }

  /// Builds the per-collection metadata key.
  static String collectionKey({
    required String userId,
    required String collection,
    required UserScope scope,
  }) {
    final segments = <String>[
      if (scope == UserScope.perDevice) escapeSegment(userId),
      escapeSegment(collection),
    ];
    return segments.join(separator);
  }

  /// Builds the cache key prefix for a user, used when purging local data.
  ///
  /// Returns `null` in [UserScope.single], where nothing is prefixed.
  static String? userPrefix({
    required String userId,
    required UserScope scope,
  }) {
    if (scope == UserScope.single) return null;
    return '${escapeSegment(userId)}$separator';
  }
}
