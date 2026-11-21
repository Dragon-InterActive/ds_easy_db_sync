import 'sync_codec.dart';

/// The persisted sync state of one collection, for one user.
///
/// Lives in the `__ds_sync__cursor` namespace.
class CollectionMeta {
  /// Creates the sync metadata for one collection.
  const CollectionMeta({
    required this.userId,
    required this.collection,
    this.cursor,
    this.lastFullSync,
  });

  /// Owner of the collection state. `SyncKeys.singleUserId` in single-user
  /// mode.
  final String userId;

  /// The collection this state belongs to.
  final String collection;

  /// The delta cursor handed back by the adapter's last completed pull.
  ///
  /// Opaque to the engine. Advanced **only after a full pull pass completed** —
  /// a partial failure must leave it untouched, or the skipped page is lost
  /// forever.
  final Object? cursor;

  /// When this collection was last pulled in full.
  ///
  /// Only set on the expensive fallback path; a delta pull does not touch it.
  final DateTime? lastFullSync;

  /// Returns a copy with the given fields replaced.
  ///
  /// A `null` [cursor] means "leave unchanged"; use [clearCursor] to reset it
  /// and force a full pull on the next pass.
  CollectionMeta copyWith({
    Object? cursor,
    DateTime? lastFullSync,
    bool clearCursor = false,
  }) {
    return CollectionMeta(
      userId: userId,
      collection: collection,
      cursor: clearCursor ? null : (cursor ?? this.cursor),
      lastFullSync: lastFullSync ?? this.lastFullSync,
    );
  }

  /// Serialises to primitive fields for storage.
  ///
  /// Throws [ArgumentError] if the adapter produced a cursor type that cannot
  /// be persisted — see [SyncCodec.encodeCursor].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'userId': userId,
      'collection': collection,
      if (cursor != null) 'cursor': SyncCodec.encodeCursor(cursor),
      if (lastFullSync != null)
        'lastFullSync': SyncCodec.encodeTime(lastFullSync),
    };
  }

  /// Restores metadata written by [toMap].
  ///
  /// Returns `null` for a malformed entry, which the engine treats as "no
  /// cursor yet" — correct, just expensive: the next pull starts from scratch.
  static CollectionMeta? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final userId = map['userId'];
    final collection = map['collection'];
    if (userId is! String || collection is! String) return null;

    return CollectionMeta(
      userId: userId,
      collection: collection,
      cursor: SyncCodec.decodeCursor(map['cursor']),
      lastFullSync: SyncCodec.decodeTime(map['lastFullSync']),
    );
  }

  @override
  String toString() => 'CollectionMeta($collection, user: $userId, '
      'cursor: $cursor, lastFullSync: $lastFullSync)';
}
