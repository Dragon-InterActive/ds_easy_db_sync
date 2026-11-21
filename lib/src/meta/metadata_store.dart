import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_sync_contract/ds_sync_contract.dart';

import 'collection_meta.dart';
import 'record_meta.dart';
import 'sync_keys.dart';

/// Persistent store for sync metadata, layered over an ordinary
/// [DatabaseRepository].
///
/// The store is backend-agnostic on purpose: it writes only primitive fields
/// into two reserved namespaces, so Hive and SQLite behave identically. It
/// holds no policy and makes no sync decisions — it answers questions like
/// "which records are dirty for the active user" and persists the answers the
/// engine writes back.
///
/// Scoping is handled here as well: in [UserScope.single] nothing is prefixed
/// and every entry carries [SyncKeys.singleUserId]; in [UserScope.perDevice]
/// keys are prefixed with the active user, so one user's data and dirty state
/// stay invisible to another.
class MetadataStore {
  /// Creates a metadata store over [repository] — normally the same `cache`
  /// slot that holds the local payload.
  MetadataStore({
    required DatabaseRepository repository,
    this.scope = UserScope.single,
  }) : _repository = repository;

  final DatabaseRepository _repository;

  /// How keys are scoped to users.
  final UserScope scope;

  String? _activeUserId;

  /// The user whose metadata is currently being read and written.
  ///
  /// Always [SyncKeys.singleUserId] in [UserScope.single]. Throws in
  /// [UserScope.perDevice] when no user is active — writing unscoped metadata
  /// there would leak one user's dirty state into another's.
  String get activeUserId {
    if (scope == UserScope.single) return SyncKeys.singleUserId;
    final userId = _activeUserId;
    if (userId == null) {
      throw StateError(
        'No active user. In UserScope.perDevice, call setActiveUser() before '
        'any sync operation.',
      );
    }
    return userId;
  }

  /// Whether a user is set (always true in [UserScope.single]).
  bool get hasActiveUser => scope == UserScope.single || _activeUserId != null;

  /// Sets the user whose data is being synced.
  ///
  /// Ignored in [UserScope.single], where there is only one user by
  /// definition.
  void setActiveUser(String userId) {
    if (scope == UserScope.single) return;
    _activeUserId = userId;
  }

  /// Clears the active user — after this, metadata access throws until a new
  /// user is set.
  void clearActiveUser() => _activeUserId = null;

  /// Reads the metadata of one record, or `null` if it has never been synced.
  Future<RecordMeta?> readRecord(String collection, String docId) async {
    final data = await _repository.get(
      SyncKeys.metaNamespace,
      _recordKey(collection, docId),
    );
    return RecordMeta.fromMap(data);
  }

  /// Writes the metadata of one record.
  Future<void> writeRecord(RecordMeta meta) async {
    await _repository.set(
      SyncKeys.metaNamespace,
      _recordKey(meta.collection, meta.docId),
      meta.toMap(),
    );
  }

  /// Removes a record's metadata entirely.
  ///
  /// Only correct once the record is truly gone on both sides — i.e. tombstone
  /// garbage collection after the remote delete was confirmed.
  Future<void> deleteRecord(String collection, String docId) async {
    await _repository.delete(
      SyncKeys.metaNamespace,
      _recordKey(collection, docId),
    );
  }

  /// All records of the active user that still need pushing.
  ///
  /// This includes tombstones — a pending delete is a pending change. Pass
  /// [collection] to scope the query to a single collection.
  ///
  /// The filter is expressed as flat field equality (`userId`, `dirty`), which
  /// a SQL backend can resolve with an indexed
  /// `WHERE userId = ? AND dirty = 1` rather than a key scan.
  Future<List<RecordMeta>> dirtyRecords({String? collection}) {
    return _queryMeta(<String, dynamic>{
      'dirty': true,
      if (collection != null) 'collection': collection,
    });
  }

  /// All tombstones of the active user, optionally scoped to [collection].
  Future<List<RecordMeta>> tombstones({String? collection}) {
    return _queryMeta(<String, dynamic>{
      'deleted': true,
      if (collection != null) 'collection': collection,
    });
  }

  /// Tombstones whose remote delete is confirmed and whose retention has
  /// elapsed — the garbage-collection candidates.
  ///
  /// The window is measured from [RecordMeta.syncedAt], the moment the backend
  /// confirmed the delete, **not** from when the user deleted locally. Those
  /// differ by the whole offline period: counting from the local delete would
  /// let a device that was offline longer than the retention collect its
  /// tombstone in the very pass that confirmed it, leaving other devices no
  /// window at all to learn about the deletion.
  ///
  /// The boundary is inclusive, so a retention of [Duration.zero] really means
  /// "collect as soon as the delete is confirmed" instead of "one tick later".
  ///
  /// A tombstone that is still dirty is never collected: its delete has not
  /// reached the backend yet, and dropping it would resurrect the record on
  /// the next pull.
  Future<List<RecordMeta>> collectableTombstones(DateTime cutoff) async {
    final all = await tombstones();
    return all.where((meta) {
      if (meta.dirty) return false;
      // No syncedAt means the delete was never confirmed by a backend, so the
      // retention clock has not started.
      final confirmedAt = meta.syncedAt;
      return confirmedAt != null && !confirmedAt.isAfter(cutoff);
    }).toList();
  }

  /// Reads the cursor state of a collection, or `null` if it has never been
  /// pulled.
  Future<CollectionMeta?> readCollection(String collection) async {
    final data = await _repository.get(
      SyncKeys.cursorNamespace,
      _collectionKey(collection),
    );
    return CollectionMeta.fromMap(data);
  }

  /// Writes the cursor state of a collection.
  Future<void> writeCollection(CollectionMeta meta) async {
    await _repository.set(
      SyncKeys.cursorNamespace,
      _collectionKey(meta.collection),
      meta.toMap(),
    );
  }

  /// Advances a collection's cursor.
  ///
  /// Call this **only after a pull pass completed in full** — advancing on a
  /// partial pass silently skips the pages that were never processed.
  Future<void> advanceCursor(
    String collection,
    Object? cursor, {
    DateTime? lastFullSync,
  }) async {
    final existing = await readCollection(collection) ??
        CollectionMeta(userId: activeUserId, collection: collection);
    await writeCollection(
      existing.copyWith(
        cursor: cursor,
        clearCursor: cursor == null,
        lastFullSync: lastFullSync,
      ),
    );
  }

  /// Deletes all metadata belonging to [userId].
  ///
  /// Local payload is *not* touched here — that is the engine's `purgeUser`,
  /// which also decides whether anything remote happens. This store only owns
  /// the metadata namespaces.
  Future<void> purgeUser(String userId) async {
    for (final namespace in const [
      SyncKeys.metaNamespace,
      SyncKeys.cursorNamespace,
    ]) {
      final entries = await _repository.getAll(namespace);
      if (entries == null) continue;

      // Collect first, delete afterwards: a backend may hand back its live
      // map, and deleting mid-iteration would throw.
      final doomed = <String>[
        for (final entry in entries.entries)
          if (entry.value is Map && (entry.value as Map)['userId'] == userId)
            entry.key,
      ];
      for (final key in doomed) {
        await _repository.delete(namespace, key);
      }
    }
  }

  Future<List<RecordMeta>> _queryMeta(Map<String, dynamic> where) async {
    final rows = await _repository.query(
      SyncKeys.metaNamespace,
      where: <String, dynamic>{'userId': activeUserId, ...where},
    );
    return rows
        .map(RecordMeta.fromMap)
        .whereType<RecordMeta>()
        .toList(growable: false);
  }

  String _recordKey(String collection, String docId) => SyncKeys.recordKey(
        userId: activeUserId,
        collection: collection,
        docId: docId,
        scope: scope,
      );

  String _collectionKey(String collection) => SyncKeys.collectionKey(
        userId: activeUserId,
        collection: collection,
        scope: scope,
      );
}
