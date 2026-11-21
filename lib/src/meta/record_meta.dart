import 'package:ds_sync_contract/ds_sync_contract.dart';

import 'sync_codec.dart';

/// The persisted sync state of a single record.
///
/// Lives in the `__ds_sync__meta` namespace, never inside the user document.
/// Everything here is *about* a record — whether it still needs pushing,
/// whether it has been tombstoned, what the remote copy looked like at the
/// last successful sync.
class RecordMeta {
  /// Creates the sync metadata for one record.
  const RecordMeta({
    required this.userId,
    required this.collection,
    required this.docId,
    required this.localUpdatedAt,
    this.dirty = false,
    this.deleted = false,
    this.syncedAt,
    this.remoteAnchor,
    this.base,
    this.retryCount = 0,
    this.serverTsFields = const <String>[],
    this.conflicted = false,
  });

  /// Owner of the record. `SyncKeys.singleUserId` in single-user mode.
  final String userId;

  /// The collection the record belongs to.
  final String collection;

  /// The record's document id.
  final String docId;

  /// Whether the record holds local changes that have not been pushed yet.
  ///
  /// Cleared only on a confirmed per-record push success, which is what makes
  /// an aborted push idempotently retryable.
  final bool dirty;

  /// Whether the record is a tombstone: hidden from reads, remote delete still
  /// pending or already done.
  final bool deleted;

  /// When the record was last written locally.
  ///
  /// Derived from the local `serverTS` resolution, never from a bare
  /// `DateTime.now()` at a call site.
  final DateTime localUpdatedAt;

  /// When the record was last confirmed in sync with the remote.
  final DateTime? syncedAt;

  /// The remote comparison anchor as of [syncedAt].
  ///
  /// Conflict detection compares an incoming record against this.
  final RemoteAnchor? remoteAnchor;

  /// The common ancestor copy, stored only when a three-way merge policy is
  /// active.
  ///
  /// This is the storage cost of `ConflictPolicy.customThreeWay` — one extra
  /// document per synced record.
  final SyncDocument? base;

  /// How often pushing this record has failed in a row.
  ///
  /// Persisted, so a restart does not reset the give-up counter. The backoff
  /// *timing* is not persisted — see `SyncRuntimeState`.
  final int retryCount;

  /// Payload fields that were written with `DatabaseRepository.serverTS`.
  ///
  /// The local cache resolves `serverTS` to `DateTime.now()` immediately, so
  /// the intent would otherwise be lost. Remembering the field names here lets
  /// the push re-send `serverTS`, so the backend — not the device — stamps the
  /// authoritative time, which is then written back into the cached document.
  ///
  /// This is metadata about the record, never part of the payload.
  final List<String> serverTsFields;

  /// Whether a conflict on this record could not be decided by its policy.
  ///
  /// Set when `lastWriteWins` has nothing to order against, or a three-way
  /// merge has no stored base yet. Such a record stays dirty but is **held
  /// back from the push**: sending the local copy would overwrite the remote
  /// edit the policy explicitly declined to rule on — a silent `clientWins`.
  ///
  /// Cleared as soon as the application writes the record again, which is the
  /// decision the engine refused to make on its behalf.
  final bool conflicted;

  /// Returns a copy with the given fields replaced.
  ///
  /// [syncedAt], [remoteAnchor] and [base] can be cleared explicitly with the
  /// matching `clear…` flags, since passing `null` means "leave unchanged".
  RecordMeta copyWith({
    bool? dirty,
    bool? deleted,
    DateTime? localUpdatedAt,
    DateTime? syncedAt,
    RemoteAnchor? remoteAnchor,
    SyncDocument? base,
    int? retryCount,
    List<String>? serverTsFields,
    bool? conflicted,
    bool clearSyncedAt = false,
    bool clearRemoteAnchor = false,
    bool clearBase = false,
  }) {
    return RecordMeta(
      userId: userId,
      collection: collection,
      docId: docId,
      dirty: dirty ?? this.dirty,
      deleted: deleted ?? this.deleted,
      localUpdatedAt: localUpdatedAt ?? this.localUpdatedAt,
      syncedAt: clearSyncedAt ? null : (syncedAt ?? this.syncedAt),
      remoteAnchor:
          clearRemoteAnchor ? null : (remoteAnchor ?? this.remoteAnchor),
      base: clearBase ? null : (base ?? this.base),
      retryCount: retryCount ?? this.retryCount,
      serverTsFields: serverTsFields ?? this.serverTsFields,
      conflicted: conflicted ?? this.conflicted,
    );
  }

  /// Serialises to primitive fields for storage.
  ///
  /// `userId`, `collection`, `dirty` and `deleted` stay flat top-level fields
  /// so a SQL backend can index them and answer "dirty records for user X"
  /// with `WHERE userId = ? AND dirty = 1` instead of scanning.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'userId': userId,
      'collection': collection,
      'docId': docId,
      'dirty': dirty,
      'deleted': deleted,
      'localUpdatedAt': SyncCodec.encodeTime(localUpdatedAt),
      if (syncedAt != null) 'syncedAt': SyncCodec.encodeTime(syncedAt),
      if (remoteAnchor != null)
        'remoteAnchor': SyncCodec.encodeAnchor(remoteAnchor),
      if (base != null) 'base': base,
      'retryCount': retryCount,
      if (serverTsFields.isNotEmpty) 'serverTsFields': serverTsFields,
      if (conflicted) 'conflicted': true,
    };
  }

  /// Restores metadata written by [toMap].
  ///
  /// Returns `null` for a malformed or incomplete entry, so a corrupt record
  /// is treated as "no metadata" rather than crashing a sync pass.
  static RecordMeta? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final userId = map['userId'];
    final collection = map['collection'];
    final docId = map['docId'];
    final localUpdatedAt = SyncCodec.decodeTime(map['localUpdatedAt']);
    if (userId is! String ||
        collection is! String ||
        docId is! String ||
        localUpdatedAt == null) {
      return null;
    }

    return RecordMeta(
      userId: userId,
      collection: collection,
      docId: docId,
      dirty: map['dirty'] == true,
      deleted: map['deleted'] == true,
      localUpdatedAt: localUpdatedAt,
      syncedAt: SyncCodec.decodeTime(map['syncedAt']),
      remoteAnchor: SyncCodec.decodeAnchor(map['remoteAnchor']),
      base: SyncCodec.asStringMap(map['base']),
      retryCount: map['retryCount'] is int ? map['retryCount'] as int : 0,
      serverTsFields: switch (map['serverTsFields']) {
        final List<dynamic> fields => fields.whereType<String>().toList(),
        _ => const <String>[],
      },
      conflicted: map['conflicted'] == true,
    );
  }

  @override
  String toString() => 'RecordMeta($collection/$docId, user: $userId, '
      'dirty: $dirty, deleted: $deleted, conflicted: $conflicted, '
      'retries: $retryCount)';
}
