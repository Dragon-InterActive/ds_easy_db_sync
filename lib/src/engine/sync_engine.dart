import 'dart:async';

import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_sync_contract/ds_sync_contract.dart';

import '../meta/metadata_store.dart';
import '../meta/record_meta.dart';
import '../meta/sync_keys.dart';
import '../meta/sync_runtime_state.dart';
import 'conflict_resolver.dart';
import 'sync_config.dart';
import 'sync_report.dart';

/// The offline-first synchronization engine.
///
/// Writes hit the local cache and return immediately — no network wait. They
/// are marked dirty in a separate metadata namespace and pushed on the next
/// sync pass, which runs **pull first, then push**.
///
/// The engine is mechanism, not policy. It never decides *when* to sync or
/// *who wins* a conflict; both come from [SyncConfig]. Nothing here starts on
/// its own: a trigger has to be attached explicitly.
class SyncEngine {
  /// Creates an unconfigured engine. Call [configure] and then [init].
  SyncEngine();

  DatabaseRepository? _local;
  SyncRemoteAdapter? _remote;
  SyncConfig? _config;
  MetadataStore? _store;
  SyncCapabilities? _capabilities;

  final SyncRuntimeState _runtime = SyncRuntimeState();

  bool _initialized = false;
  bool _forceFullPull = false;
  Future<void>? _pass;
  Timer? _periodicTimer;
  StreamSubscription<bool>? _connectivitySubscription;

  /// Whether [init] has completed.
  bool get isInitialized => _initialized;

  /// The capabilities the configured adapter declared.
  SyncCapabilities get capabilities => _requireCapabilities();

  /// The active configuration.
  SyncConfig get config => _requireConfig();

  /// The metadata store, exposed for diagnostics and tests.
  MetadataStore get metadata => _requireStore();

  /// Wires the engine to its two repositories and the application's policy.
  ///
  /// [local] is the `cache` slot — first write target and read source.
  /// [remote] is the sync-capable adapter wrapping the `storage` slot.
  void configure({
    required DatabaseRepository local,
    required SyncRemoteAdapter remote,
    required SyncConfig config,
  }) {
    for (final collection in config.collections) {
      if (SyncKeys.isReserved(collection)) {
        throw ArgumentError.value(
          collection,
          'config.collections',
          'The prefix "${SyncKeys.reservedPrefix}" is reserved for sync '
              'metadata and must not be synced as payload.',
        );
      }
    }

    _local = local;
    _remote = remote;
    _config = config;
    _store = MetadataStore(repository: local, scope: config.userScope);
    _capabilities = null;
    _initialized = false;
  }

  /// Runs the capability checks and makes the engine usable.
  ///
  /// Throws [SyncCapabilityException] when a capability is missing whose
  /// absence risks data loss and whose fallback is
  /// [CapabilityFallback.strict].
  Future<void> init() async {
    final config = _requireConfig();
    final remote = _requireRemote();
    final capabilities = remote.capabilities;
    _capabilities = capabilities;

    final hasAnchor = capabilities.supportsVersioning ||
        capabilities.supportsTimestamps ||
        capabilities.supportsContentHash;
    if (!hasAnchor) {
      _handleMissingCapability(
        fallback: config.missingConflictAnchor,
        message: 'The adapter provides no conflict anchor (no versioning, no '
            'timestamps, no content hash). Conflicts cannot be detected, so '
            'concurrent edits would be overwritten silently.',
      );
    }

    final needsTimestamps = _usesTimestampPolicies(config);
    if (needsTimestamps && !capabilities.supportsTimestamps) {
      _handleMissingCapability(
        fallback: config.missingConflictAnchor,
        message: 'A lastWriteWins policy is configured, but the adapter '
            'provides no timestamps. "Newer" cannot be determined, so the '
            'policy could not be applied.',
      );
    }

    if (!capabilities.supportsDeltaPull) {
      _forceFullPull = true;
      _handleMissingCapability(
        fallback: config.missingDeltaPull,
        message: 'The adapter cannot pull deltas. Falling back to full pulls '
            'with simulated delta — correct, but the network cost grows with '
            'collection size.',
      );
    } else if (!capabilities.supportsDeltaDeletes) {
      _forceFullPull = true;
      _handleMissingCapability(
        fallback: config.missingDeltaDeletes,
        message: 'The adapter cannot report remote deletions in a delta pull. '
            'Falling back to full pulls, because a delta pull alone would '
            'leave remotely deleted records alive locally.',
      );
    }

    await _local!.init();
    _initialized = true;
  }

  // ---------------------------------------------------------------- users

  /// Whether a sync pass, [flush] or [purgeUser] is running right now.
  bool get isSyncing => _pass != null;

  /// Completes once no sync pass, [flush] or [purgeUser] is running.
  ///
  /// Code placed directly after `await engine.whenIdle()` runs before any
  /// trigger can start a new pass, so it is the safe point to switch users:
  ///
  /// ```dart
  /// await engine.whenIdle();
  /// engine.setActiveUser(nextUserId);
  /// ```
  Future<void> whenIdle() async {
    while (_pass != null) {
      await _pass;
    }
  }

  /// Sets the user whose data is synced from now on.
  ///
  /// Clears runtime backoff state: another user's rate limit is not this
  /// user's problem. Persisted dirty flags are untouched, so the previous
  /// user's unpushed changes survive the switch.
  ///
  /// Throws [SyncBusyException] while [isSyncing]: a running pass would carry
  /// on under the new user and mix both users' metadata. Await [whenIdle]
  /// first.
  void setActiveUser(String userId) {
    _requireIdle('setActiveUser');
    _requireStore().setActiveUser(userId);
    _runtime.clear();
  }

  /// Clears the active user. In [UserScope.perDevice], sync operations throw
  /// until a new user is set.
  ///
  /// Throws [SyncBusyException] while [isSyncing]; await [whenIdle] first.
  void clearActiveUser() {
    _requireIdle('clearActiveUser');
    _requireStore().clearActiveUser();
    _runtime.clear();
  }

  void _requireIdle(String operation) {
    if (_pass != null) {
      throw SyncBusyException(
        '$operation() was called while a sync pass, flush or purge is '
        'running. Await whenIdle() first, then switch users.',
      );
    }
  }

  /// Removes a user's data from this device.
  ///
  /// With [PurgeScope.localAndRemote] the engine additionally invokes
  /// [SyncConfig.onPurgeRemote] — it deletes nothing remotely itself, because
  /// what "delete this user" means for accounts, auth and retention duties is
  /// the application's call, not a sync engine's.
  ///
  /// Waits for a running sync pass to finish first: the purge switches the
  /// active user temporarily, which must not happen under a running pass.
  Future<void> purgeUser(
    String userId, {
    PurgeScope scope = PurgeScope.local,
  }) =>
      _exclusive(() => _purgeUser(userId, scope));

  Future<void> _purgeUser(String userId, PurgeScope scope) async {
    final config = _requireConfig();
    final store = _requireStore();
    final local = _requireLocal();

    final previousUser =
        store.hasActiveUser && config.userScope == UserScope.perDevice
            ? store.activeUserId
            : null;
    store.setActiveUser(userId);

    for (final collection in config.collections) {
      final all = await local.getAll(collection);
      if (all == null) continue;
      final doomed = <String>[
        for (final key in all.keys)
          if (_ownsCacheKey(key, userId)) key,
      ];
      for (final key in doomed) {
        await local.delete(collection, key);
      }
    }
    // In UserScope.single every metadata entry carries SyncKeys.singleUserId,
    // not the id passed in; purging by that id would leave dirty flags and the
    // cursor behind, and the cursor would keep the next pull from restoring
    // the payload just deleted.
    await store.purgeUser(store.activeUserId);
    _runtime.clear();

    if (scope == PurgeScope.localAndRemote) {
      final handler = config.onPurgeRemote;
      if (handler == null) {
        _warn('purgeUser(localAndRemote) was requested but no onPurgeRemote '
            'handler is configured. Only local data was removed.');
      } else {
        await handler(userId);
      }
    }

    if (previousUser != null && previousUser != userId) {
      store.setActiveUser(previousUser);
    } else if (config.userScope == UserScope.perDevice) {
      store.clearActiveUser();
    }
  }

  // ----------------------------------------------------------- write path

  /// Writes a document locally and marks it for pushing.
  ///
  /// Returns as soon as the local write is done — the network is never waited
  /// on. Fields set to [DatabaseRepository.serverTS] are remembered in the
  /// metadata so the push can re-send them and let the backend stamp the
  /// authoritative time.
  Future<void> set(
    String collection,
    String docId,
    Map<String, dynamic> data,
  ) async {
    _requireReady();
    final store = _requireStore();
    await _requireLocal().set(collection, _cacheKey(docId), data);
    _runtime.noteLocalWrite(_runtimeKey(collection, docId));

    final existing = await store.readRecord(collection, docId);
    await store.writeRecord(
      (existing ??
              RecordMeta(
                userId: store.activeUserId,
                collection: collection,
                docId: docId,
                localUpdatedAt: _now(),
              ))
          .copyWith(
        dirty: true,
        deleted: false,
        conflicted: false,
        localUpdatedAt: _now(),
        retryCount: 0,
        serverTsFields: _serverTsFields(data),
      ),
    );
    _runtime.clearNextRetry(_runtimeKey(collection, docId));
  }

  /// Updates individual fields locally and marks the record for pushing.
  ///
  /// On a soft-deleted record this starts a new document from [data] alone:
  /// the hidden payload of the tombstone must not come back to life.
  Future<void> update(
    String collection,
    String docId,
    Map<String, dynamic> data,
  ) async {
    _requireReady();
    final store = _requireStore();
    final existing = await store.readRecord(collection, docId);
    final revives = existing?.deleted ?? false;

    if (revives) {
      await _requireLocal().set(collection, _cacheKey(docId), data);
    } else {
      await _requireLocal().update(collection, _cacheKey(docId), data);
    }
    _runtime.noteLocalWrite(_runtimeKey(collection, docId));

    final mergedTsFields = <String>{
      if (!revives) ...?existing?.serverTsFields,
      ..._serverTsFields(data),
    }.toList();

    await store.writeRecord(
      (existing ??
              RecordMeta(
                userId: store.activeUserId,
                collection: collection,
                docId: docId,
                localUpdatedAt: _now(),
              ))
          .copyWith(
        dirty: true,
        deleted: false,
        conflicted: false,
        localUpdatedAt: _now(),
        retryCount: 0,
        serverTsFields: mergedTsFields,
      ),
    );
    _runtime.clearNextRetry(_runtimeKey(collection, docId));
  }

  /// Soft-deletes a document.
  ///
  /// The payload stays in the cache but is hidden from every read, the record
  /// is marked as a dirty tombstone, and the real remote delete happens on the
  /// next push. There is deliberately no hard local delete: a record removed
  /// before its delete reached the backend would come back on the next pull.
  Future<void> delete(String collection, String docId) async {
    _requireReady();
    final store = _requireStore();
    _runtime.noteLocalWrite(_runtimeKey(collection, docId));
    final existing = await store.readRecord(collection, docId);

    await store.writeRecord(
      (existing ??
              RecordMeta(
                userId: store.activeUserId,
                collection: collection,
                docId: docId,
                localUpdatedAt: _now(),
              ))
          .copyWith(
        dirty: true,
        deleted: true,
        conflicted: false,
        localUpdatedAt: _now(),
        retryCount: 0,
      ),
    );
    _runtime.clearNextRetry(_runtimeKey(collection, docId));
  }

  // ------------------------------------------------------------ read path

  /// Reads a document from the local cache.
  ///
  /// Returns `null` for a tombstoned record — a soft-deleted document must be
  /// as invisible as a hard-deleted one.
  Future<Map<String, dynamic>?> get(
    String collection,
    String docId, {
    Map<String, dynamic>? defaultValue,
  }) async {
    _requireReady();
    final meta = await _requireStore().readRecord(collection, docId);
    if (meta != null && meta.deleted) return defaultValue;
    final data = await _requireLocal().get(collection, _cacheKey(docId));
    return data ?? defaultValue;
  }

  /// Reads every visible document of a collection, keyed by document id.
  ///
  /// Tombstones are excluded. Returns `null` when nothing is visible.
  Future<Map<String, dynamic>?> getAll(String collection) async {
    _requireReady();
    final visible = await _visibleDocuments(collection);
    return visible.isEmpty ? null : visible;
  }

  /// Returns the visible documents of [collection] matching [where], each
  /// with its document id under `id`, like every `ds_easy_db` backend.
  ///
  /// A document that carries its own `id` field keeps it.
  ///
  /// Filtering happens in the engine on the visible documents, so tombstones
  /// and other users' records are excluded reliably. For large collections,
  /// keep the synced set narrow.
  Future<List<Map<String, dynamic>>> query(
    String collection, {
    Map<String, dynamic> where = const <String, dynamic>{},
  }) async {
    _requireReady();
    final visible = await _visibleDocuments(collection);
    return <Map<String, dynamic>>[
      for (final entry in visible.entries)
        if (entry.value case final Map<String, dynamic> doc
            when _matches(doc, where))
          <String, dynamic>{'id': entry.key, ...doc},
    ];
  }

  /// Whether a visible (non-tombstoned) document exists.
  Future<bool> exists(String collection, String docId) async {
    return await get(collection, docId) != null;
  }

  // ----------------------------------------------------------------- sync

  /// Runs a full pass over every configured collection: pull, then push.
  ///
  /// Skipped with a warning while another pass, a [flush] or a [purgeUser]
  /// is running.
  Future<SyncReport> sync({List<String>? collections}) async {
    _requireReady();
    if (_pass != null) {
      _warn('A sync pass is already running; this call was skipped.');
      return const SyncReport();
    }
    return _exclusive(() async {
      var report = const SyncReport(cursorAdvanced: true);
      for (final collection in collections ?? _requireConfig().collections) {
        report = report.merge(await _syncCollection(collection));
      }
      return report;
    });
  }

  /// Runs a pass over a single collection.
  Future<SyncReport> syncCollection(String collection) async {
    _requireReady();
    if (_pass != null) {
      _warn('A sync pass is already running; this call was skipped.');
      return const SyncReport();
    }
    return _exclusive(() => _syncCollection(collection));
  }

  /// Pushes pending local changes without pulling first.
  ///
  /// Useful before logout — but it is not the safety net. Durability comes
  /// from the cache and its dirty flags being persistent, so unpushed changes
  /// survive an app kill and are picked up by the next pass.
  ///
  /// Unlike [sync], a flush is not skipped while a pass is running: it waits
  /// for that pass and then pushes whatever is still pending, so a flush right
  /// before logout never returns without having tried.
  Future<SyncReport> flush({List<String>? collections}) async {
    _requireReady();
    return _exclusive(() async {
      var report = const SyncReport(cursorAdvanced: true);
      for (final collection in collections ?? _requireConfig().collections) {
        final builder = SyncReportBuilder()..cursorAdvanced = true;
        await _push(collection, builder);
        report = report.merge(builder.build());
      }
      return report;
    });
  }

  /// Runs [body] once no other sync pass, flush or purge is running.
  Future<T> _exclusive<T>(Future<T> Function() body) async {
    while (_pass != null) {
      await _pass;
    }
    final done = Completer<void>();
    _pass = done.future;
    try {
      return await body();
    } finally {
      _pass = null;
      done.complete();
    }
  }

  Future<SyncReport> _syncCollection(String collection) async {
    final builder = SyncReportBuilder();
    await _pull(collection, builder);
    await _push(collection, builder);
    await _collectTombstones(collection, builder);
    return builder.build();
  }

  // ----------------------------------------------------------------- pull

  Future<void> _pull(String collection, SyncReportBuilder report) async {
    final store = _requireStore();
    final remote = _requireRemote();
    final fullPull = _forceFullPull;

    final collectionMeta = await store.readCollection(collection);
    var cursor = fullPull ? null : collectionMeta?.cursor;
    Object? lastCursor = collectionMeta?.cursor;
    final seenRemoteIds = <String>{};

    var pages = 0;
    while (true) {
      final DeltaResult page;
      try {
        page = await remote.pullSince(collection, cursor);
      } catch (error, stackTrace) {
        final syncError = _toSyncError(remote, error, stackTrace);
        report.failed++;
        report.errors.add(syncError);
        await _dispatchError(
          SyncErrorContext(collection: collection, error: syncError),
        );
        // Cursor stays where it was: a partial pull must never advance it,
        // or the pages that were never processed are lost for good.
        return;
      }

      for (final record in page.changed) {
        seenRemoteIds.add(record.id);
        await _applyRemoteChange(collection, record, report);
      }
      for (final docId in page.deleted) {
        await _applyRemoteDelete(collection, docId, report);
      }

      final requestedCursor = cursor;
      cursor = page.nextCursor;
      lastCursor = page.nextCursor;
      pages++;
      if (!page.hasMore) break;
      if (page.nextCursor == null) {
        _warn('The adapter reported hasMore without a nextCursor for '
            '"$collection"; stopping after page $pages to avoid a loop.');
        break;
      }
      if (page.nextCursor == requestedCursor) {
        _warn('The adapter reported hasMore but its cursor did not advance '
            'for "$collection"; stopping after page $pages to avoid a loop.');
        break;
      }
    }

    if (fullPull) {
      await _reconcileMissingLocally(collection, seenRemoteIds, report);
    }

    await store.advanceCursor(
      collection,
      lastCursor,
      lastFullSync: fullPull ? _now() : null,
    );
    report.cursorAdvanced = true;
  }

  /// On a full pull, a record that exists locally but no longer remotely was
  /// deleted on the server — a delta pull would have told us, a full one has
  /// to infer it.
  Future<void> _reconcileMissingLocally(
    String collection,
    Set<String> seenRemoteIds,
    SyncReportBuilder report,
  ) async {
    final store = _requireStore();
    final local = _requireLocal();
    final all = await local.getAll(collection);
    if (all == null) return;

    for (final key in all.keys.toList()) {
      if (!_ownsCacheKey(key, store.activeUserId)) continue;
      final docId = _docIdFromCacheKey(key);
      if (seenRemoteIds.contains(docId)) continue;

      final meta = await store.readRecord(collection, docId);
      // Never synced yet: a purely local record the remote has not seen.
      if (meta == null || (meta.dirty && meta.syncedAt == null)) continue;
      await _applyRemoteDelete(collection, docId, report);
    }
  }

  Future<void> _applyRemoteChange(
    String collection,
    RemoteRecord record,
    SyncReportBuilder report,
  ) async {
    final store = _requireStore();
    final local = _requireLocal();
    final config = _requireConfig();
    final meta = await store.readRecord(collection, record.id);

    // The remote copy has not moved on since the last sync. On a full pull
    // (simulated delta) every unchanged record arrives again, and a delta pull
    // may repeat its boundary record. Without a remote change there is no
    // conflict: a clean record is already current, and a dirty one — edit or
    // tombstone — simply gets pushed. Handing it to a policy instead would let
    // serverWins revert a local edit or resurrect a local delete.
    if (meta != null &&
        meta.remoteAnchor != null &&
        meta.remoteAnchor == record.anchor) {
      return;
    }

    if (meta == null || !meta.dirty) {
      await local.set(collection, _cacheKey(record.id), record.data);
      await store.writeRecord(
        (meta ??
                RecordMeta(
                  userId: store.activeUserId,
                  collection: collection,
                  docId: record.id,
                  localUpdatedAt: _now(),
                ))
            .copyWith(
          dirty: false,
          deleted: false,
          syncedAt: _now(),
          remoteAnchor: record.anchor,
          retryCount: 0,
          base: _storesBase(collection) ? record.data : null,
        ),
      );
      report.pulled++;
      return;
    }

    // Locally dirty and remotely changed — this is a conflict.
    report.conflicts++;

    if (meta.deleted) {
      await _resolveDeleteConflict(
        collection: collection,
        docId: record.id,
        direction: DeleteConflictDirection.localDeleteRemoteModify,
        survivingDocument: record.data,
        meta: meta,
        remoteAnchor: record.anchor,
        remoteTime: record.anchor.updatedAt,
        report: report,
      );
      return;
    }

    final localData =
        await local.get(collection, _cacheKey(record.id)) ?? const {};
    final outcome = ConflictResolver.resolveContent(
      policy: config.policyFor(collection),
      local: Map<String, dynamic>.from(localData),
      remote: record.data,
      localUpdatedAt: meta.localUpdatedAt,
      remoteUpdatedAt: record.anchor.updatedAt,
      base: meta.base,
    );

    if (outcome.warning != null) _warn(outcome.warning!);
    if (!outcome.resolved) report.unresolved++;

    await local.set(collection, _cacheKey(record.id), outcome.document);
    await store.writeRecord(
      meta.copyWith(
        dirty: outcome.stillDirty,
        // A policy that declined to decide must not have its "keep local"
        // fallback turn into a push: that would overwrite the remote edit and
        // amount to a silent clientWins. The record is held back until the
        // application writes it again.
        conflicted: !outcome.resolved,
        localUpdatedAt: outcome.stillDirty ? _now() : meta.localUpdatedAt,
        syncedAt: outcome.stillDirty ? null : _now(),
        // Keep the anchor we merged against, even when the result stays
        // dirty: the push needs it to tell "resolved" from "stale".
        remoteAnchor: record.anchor,
        base: _storesBase(collection) ? record.data : null,
        retryCount: 0,
      ),
    );
    report.pulled++;
  }

  Future<void> _applyRemoteDelete(
    String collection,
    String docId,
    SyncReportBuilder report,
  ) async {
    final store = _requireStore();
    final local = _requireLocal();
    final meta = await store.readRecord(collection, docId);

    if (meta == null) {
      await local.delete(collection, _cacheKey(docId));
      report.deletedLocally++;
      return;
    }

    if (meta.deleted) {
      // Deleted on both sides — convergent, not a conflict. The tombstone is
      // confirmed and then waits out its retention; collecting it here would
      // let a device that is still offline resurrect the record.
      if (meta.dirty) {
        await store.writeRecord(
          meta.copyWith(dirty: false, syncedAt: _now(), retryCount: 0),
        );
        report.deletedRemotely++;
      }
      return;
    }

    if (!meta.dirty) {
      // The remote deleted a record we had no local changes to. Nothing to
      // push and nothing to lose, so the local copy and its metadata go.
      await local.delete(collection, _cacheKey(docId));
      await store.deleteRecord(collection, docId);
      report.deletedLocally++;
      return;
    }

    report.conflicts++;
    final localData = await local.get(collection, _cacheKey(docId)) ?? const {};
    await _resolveDeleteConflict(
      collection: collection,
      docId: docId,
      direction: DeleteConflictDirection.localModifyRemoteDelete,
      survivingDocument: Map<String, dynamic>.from(localData),
      meta: meta,
      remoteAnchor: meta.remoteAnchor,
      remoteTime: null,
      report: report,
    );
  }

  Future<void> _resolveDeleteConflict({
    required String collection,
    required String docId,
    required DeleteConflictDirection direction,
    required SyncDocument survivingDocument,
    required RecordMeta meta,
    required RemoteAnchor? remoteAnchor,
    required DateTime? remoteTime,
    required SyncReportBuilder report,
  }) async {
    final store = _requireStore();
    final local = _requireLocal();
    final localDeleted =
        direction == DeleteConflictDirection.localDeleteRemoteModify;

    final resolution = ConflictResolver.resolveDelete(
      policy: _requireConfig().deletePolicyFor(collection),
      context: DeleteConflictContext(
        collection: collection,
        docId: docId,
        direction: direction,
        survivingDocument: survivingDocument,
      ),
      deletedAt: localDeleted ? meta.localUpdatedAt : remoteTime,
      modifiedAt: localDeleted ? remoteTime : meta.localUpdatedAt,
    );
    if (resolution.warning != null) _warn(resolution.warning!);

    switch (resolution.outcome) {
      case DeleteOutcome():
        // The record dies. If the remote still has it, the delete has to be
        // pushed; if the remote already deleted it, there is nothing to send.
        if (localDeleted) {
          await store.writeRecord(
            meta.copyWith(deleted: true, dirty: true, retryCount: 0),
          );
        } else {
          await local.delete(collection, _cacheKey(docId));
          await store.deleteRecord(collection, docId);
          report.deletedLocally++;
        }

      case KeepOutcome(:final document):
        // The record survives, and the side that deleted it has to learn
        // about that — so it stays dirty and gets pushed.
        await local.set(collection, _cacheKey(docId), document);
        await store.writeRecord(
          meta.copyWith(
            deleted: false,
            dirty: true,
            localUpdatedAt: _now(),
            remoteAnchor: remoteAnchor,
            retryCount: 0,
          ),
        );
    }
  }

  // ----------------------------------------------------------------- push

  Future<void> _push(String collection, SyncReportBuilder report) async {
    final store = _requireStore();
    final config = _requireConfig();
    final remote = _requireRemote();
    final local = _requireLocal();
    final now = _now();

    final pending = <RecordMeta>[
      for (final meta in await store.dirtyRecords(collection: collection))
        // A record whose conflict no policy could decide is deliberately not
        // pushed — see RecordMeta.conflicted.
        if (!meta.conflicted &&
            _runtime.isEligible(_runtimeKey(collection, meta.docId), now) &&
            meta.retryCount < config.maxRetries)
          meta,
    ];
    if (pending.isEmpty) return;

    for (var offset = 0;
        offset < pending.length;
        offset += config.pushBatchSize) {
      final slice = pending.sublist(
        offset,
        (offset + config.pushBatchSize).clamp(0, pending.length),
      );

      final items = <PushItem>[];
      final byId = <String, _PushSnapshot>{};
      for (final meta in slice) {
        // Taken before the payload is read: any write from here on shows up
        // as a changed counter when the result comes back.
        final sequence =
            _runtime.writeSequence(_runtimeKey(collection, meta.docId));
        if (meta.deleted) {
          byId[meta.docId] = _PushSnapshot(meta, sequence);
          items.add(PushItem.delete(
            collection: collection,
            id: meta.docId,
            localUpdatedAt: meta.localUpdatedAt,
            baseAnchor: meta.remoteAnchor,
          ));
          continue;
        }
        final data = await local.get(collection, _cacheKey(meta.docId));
        if (data == null) {
          // Payload gone but metadata says dirty — nothing meaningful can be
          // pushed. Drop the stale metadata instead of retrying forever.
          _warn('No payload for dirty record "$collection/${meta.docId}"; '
              'its stale metadata was dropped.');
          await store.deleteRecord(collection, meta.docId);
          continue;
        }
        byId[meta.docId] = _PushSnapshot(meta, sequence);
        items.add(PushItem(
          collection: collection,
          id: meta.docId,
          document: _restoreServerTs(data, meta.serverTsFields),
          localUpdatedAt: meta.localUpdatedAt,
          baseAnchor: meta.remoteAnchor,
        ));
      }
      if (items.isEmpty) continue;

      for (final item in items) {
        _runtime.markInFlight(_runtimeKey(collection, item.id));
      }

      List<PushResult> results;
      try {
        results = await remote.pushBatch(items);
      } catch (error, stackTrace) {
        final syncError = _toSyncError(remote, error, stackTrace);
        results = <PushResult>[
          for (final item in items)
            PushResult(
              id: item.id,
              status: PushStatus.failed,
              error: syncError,
            ),
        ];
      } finally {
        for (final item in items) {
          _runtime.clearInFlight(_runtimeKey(collection, item.id));
        }
      }

      for (final result in results) {
        final snapshot = byId[result.id];
        if (snapshot == null) continue;
        await _applyPushResult(collection, snapshot, result, report);
      }
    }
  }

  Future<void> _applyPushResult(
    String collection,
    _PushSnapshot snapshot,
    PushResult result,
    SyncReportBuilder report,
  ) async {
    final store = _requireStore();
    final local = _requireLocal();
    final pushed = snapshot.meta;
    final runtimeKey = _runtimeKey(collection, pushed.docId);

    // Re-read instead of writing back the snapshot: the application may have
    // written the record while the push was on the wire, and overwriting that
    // newer metadata would silently lose the write.
    final current = await store.readRecord(collection, pushed.docId);
    if (current == null) {
      // Metadata dropped meanwhile (purge, dropRecord): nothing to update.
      _runtime.clearNextRetry(runtimeKey);
      return;
    }
    final writtenSince =
        _runtime.writeSequence(runtimeKey) != snapshot.sequence ||
            current.localUpdatedAt != pushed.localUpdatedAt ||
            current.deleted != pushed.deleted;

    switch (result.status) {
      case PushStatus.success:
        _runtime.clearNextRetry(runtimeKey);
        if (writtenSince) {
          // The pushed state is confirmed, but a newer local write is still
          // pending. It stays dirty and goes out on the next push, based on
          // the anchor this push produced.
          await store.writeRecord(
            current.copyWith(
              syncedAt: _now(),
              retryCount: 0,
              remoteAnchor: result.newAnchor,
              clearRemoteAnchor: pushed.deleted && result.newAnchor == null,
            ),
          );
          if (pushed.deleted) {
            report.deletedRemotely++;
          } else {
            report.pushed++;
          }
          return;
        }

        if (pushed.deleted) {
          // The tombstone stays until its retention elapses: dropping it now
          // would let another device's stale copy resurrect the record.
          await store.writeRecord(
            current.copyWith(
              dirty: false,
              syncedAt: _now(),
              retryCount: 0,
              remoteAnchor: result.newAnchor,
            ),
          );
          report.deletedRemotely++;
          return;
        }

        // Write the authoritative server time back into the cached document,
        // replacing the DateTime.now() the local cache had substituted. Once
        // that happened the fields are done: the next push sends the stamped
        // value instead of asking the backend to stamp them again.
        final serverTime = result.newAnchor?.updatedAt;
        final stamped = serverTime != null && current.serverTsFields.isNotEmpty;
        if (stamped) {
          await local
              .update(collection, _cacheKey(pushed.docId), <String, dynamic>{
            for (final field in current.serverTsFields) field: serverTime,
          });
        }

        await store.writeRecord(
          current.copyWith(
            dirty: false,
            syncedAt: _now(),
            retryCount: 0,
            remoteAnchor: result.newAnchor,
            serverTsFields: stamped ? const <String>[] : null,
          ),
        );
        report.pushed++;

      case PushStatus.conflict:
        // The backend saw a newer remote copy. Resolving needs that copy, so
        // the record stays dirty and the next pull hands it to the policy.
        // Not counted as a failure: nothing is broken and nothing is lost.
        await store.writeRecord(current.copyWith(retryCount: 0));
        if (result.error != null) report.errors.add(result.error!);
        _warn('Push of "$collection/${pushed.docId}" conflicted; it stays '
            'dirty and is resolved on the next pull.');

      case PushStatus.failed:
        final error = result.error ?? const SyncError(SyncErrorKind.permanent);
        report.failed++;
        report.errors.add(error);

        final resolution = await _dispatchError(
          SyncErrorContext(
            collection: collection,
            docId: pushed.docId,
            error: error,
            retryCount: current.retryCount,
          ),
        );

        switch (resolution) {
          case SyncResolution.retryNow:
            _runtime.clearNextRetry(runtimeKey);
            await store.writeRecord(current.copyWith(retryCount: 0));
          case SyncResolution.dropRecord:
            await local.delete(collection, _cacheKey(pushed.docId));
            await store.deleteRecord(collection, pushed.docId);
            _runtime.clearNextRetry(runtimeKey);
          case SyncResolution.leaveDirty:
          case null:
            if (writtenSince) {
              // A newer write deserves its own attempts; the failure belongs
              // to the state that was pushed.
              await store.writeRecord(current.copyWith(retryCount: 0));
              return;
            }
            final attempts = current.retryCount + 1;
            await store.writeRecord(current.copyWith(retryCount: attempts));
            _runtime.setNextRetry(
              runtimeKey,
              _now().add(_backoffFor(error.kind, attempts)),
            );
            if (attempts >= _requireConfig().maxRetries) {
              _warn('Giving up on "$collection/${pushed.docId}" after '
                  '$attempts attempts (${error.kind.name}). It stays dirty and '
                  'is left to the application.');
            }
        }
    }
  }

  Duration _backoffFor(SyncErrorKind kind, int attempts) {
    final config = _requireConfig();
    final base = kind == SyncErrorKind.rateLimited
        ? config.rateLimitBackoff
        : config.initialBackoff;
    final factor = 1 << (attempts - 1).clamp(0, 16);
    final scaled = base * factor;
    return scaled > config.maxBackoff ? config.maxBackoff : scaled;
  }

  Future<SyncResolution?> _dispatchError(SyncErrorContext context) async {
    final config = _requireConfig();
    final handler = switch (context.error.kind) {
      SyncErrorKind.unauthorized => config.onUnauthorized,
      SyncErrorKind.quotaExceeded => config.onQuotaExceeded,
      SyncErrorKind.paymentRequired => config.onPaymentRequired,
      _ => null,
    };
    return await (handler ?? config.onSyncError)?.call(context);
  }

  // ------------------------------------------------------------ tombstones

  Future<void> _collectTombstones(
    String collection,
    SyncReportBuilder report,
  ) async {
    final store = _requireStore();
    final local = _requireLocal();
    final cutoff = _now().subtract(_requireConfig().tombstoneRetention);

    for (final meta in await store.collectableTombstones(cutoff)) {
      if (meta.collection != collection) continue;
      await local.delete(collection, _cacheKey(meta.docId));
      await store.deleteRecord(collection, meta.docId);
      report.tombstonesCollected++;
    }
  }

  // --------------------------------------------------------------- triggers

  /// Syncs whenever [onlineStream] reports that connectivity returned.
  ///
  /// Opt-in — the engine never watches connectivity on its own. Only one
  /// trigger stream is active at a time.
  void attachConnectivityTrigger(Stream<bool> onlineStream) {
    _requireReady();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = onlineStream.listen((online) {
      if (online) unawaited(sync());
    });
  }

  /// Syncs every [interval].
  ///
  /// Opt-in, and never a substitute for durability: unpushed changes survive
  /// without it, because dirty flags are persistent.
  void startPeriodicSync(Duration interval) {
    _requireReady();
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(interval, (_) => unawaited(sync()));
  }

  /// Stops periodic and connectivity triggers and releases their resources.
  Future<void> dispose() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _runtime.clear();
  }

  // --------------------------------------------------------------- helpers

  Future<Map<String, dynamic>> _visibleDocuments(String collection) async {
    final store = _requireStore();
    final all = await _requireLocal().getAll(collection);
    if (all == null) return <String, dynamic>{};

    final hidden = <String>{
      for (final meta in await store.tombstones(collection: collection))
        meta.docId,
    };

    final visible = <String, dynamic>{};
    for (final entry in all.entries) {
      if (!_ownsCacheKey(entry.key, store.activeUserId)) continue;
      final docId = _docIdFromCacheKey(entry.key);
      if (hidden.contains(docId)) continue;
      visible[docId] = entry.value;
    }
    return visible;
  }

  bool _matches(Map<String, dynamic> doc, Map<String, dynamic> where) {
    for (final entry in where.entries) {
      if (doc[entry.key] != entry.value) return false;
    }
    return true;
  }

  List<String> _serverTsFields(Map<String, dynamic> data) => <String>[
        for (final entry in data.entries)
          if (entry.value == DatabaseRepository.serverTS) entry.key,
      ];

  Map<String, dynamic> _restoreServerTs(
    Map<String, dynamic> data,
    List<String> fields,
  ) {
    if (fields.isEmpty) return Map<String, dynamic>.from(data);
    return <String, dynamic>{
      ...data,
      for (final field in fields) field: DatabaseRepository.serverTS,
    };
  }

  bool _storesBase(String collection) =>
      _requireConfig().policyFor(collection) is CustomThreeWayMergePolicy;

  String _cacheKey(String docId) {
    final store = _requireStore();
    if (store.scope == UserScope.single) return docId;
    return '${SyncKeys.escapeSegment(store.activeUserId)}'
        '${SyncKeys.separator}${SyncKeys.escapeSegment(docId)}';
  }

  bool _ownsCacheKey(String cacheKey, String userId) {
    if (_requireStore().scope == UserScope.single) return true;
    return cacheKey.startsWith(
      '${SyncKeys.escapeSegment(userId)}${SyncKeys.separator}',
    );
  }

  String _docIdFromCacheKey(String cacheKey) {
    final store = _requireStore();
    if (store.scope == UserScope.single) return cacheKey;
    final prefix = '${SyncKeys.escapeSegment(store.activeUserId)}'
        '${SyncKeys.separator}';
    final withoutPrefix = cacheKey.startsWith(prefix)
        ? cacheKey.substring(prefix.length)
        : cacheKey;
    return withoutPrefix.replaceAll(r'\:', ':').replaceAll(r'\\', r'\');
  }

  String _runtimeKey(String collection, String docId) =>
      '$collection${SyncKeys.separator}$docId';

  SyncError _toSyncError(
    SyncRemoteAdapter remote,
    Object error,
    StackTrace stackTrace,
  ) {
    if (error is SyncError) return error;
    return remote.mapError(error, stackTrace);
  }

  bool _usesTimestampPolicies(SyncConfig config) {
    final policies = <Object>[
      config.defaultPolicy,
      ...config.collectionPolicies.values,
      config.defaultDeletePolicy,
      ...config.collectionDeletePolicies.values,
    ];
    return policies.any(
      (policy) =>
          policy is LastWriteWinsPolicy || policy is DeleteLastWriteWinsPolicy,
    );
  }

  void _handleMissingCapability({
    required CapabilityFallback fallback,
    required String message,
  }) {
    if (fallback == CapabilityFallback.strict) {
      throw SyncCapabilityException(message);
    }
    _warn(message);
  }

  void _warn(String message) => _requireConfig().onWarning?.call(message);

  DateTime _now() => _requireConfig().clock();

  DatabaseRepository _requireLocal() =>
      _local ?? (throw const SyncNotInitializedException('configure() first.'));

  SyncRemoteAdapter _requireRemote() =>
      _remote ??
      (throw const SyncNotInitializedException('configure() first.'));

  SyncConfig _requireConfig() =>
      _config ??
      (throw const SyncNotInitializedException('configure() first.'));

  MetadataStore _requireStore() =>
      _store ?? (throw const SyncNotInitializedException('configure() first.'));

  SyncCapabilities _requireCapabilities() =>
      _capabilities ??
      (throw const SyncNotInitializedException('init() first.'));

  void _requireReady() {
    if (!_initialized) {
      throw const SyncNotInitializedException(
        'Call configure() and await init() before using the engine.',
      );
    }
  }
}

/// What a push sent for one record, kept until its result comes back.
class _PushSnapshot {
  const _PushSnapshot(this.meta, this.sequence);

  /// The metadata the push was built from.
  final RecordMeta meta;

  /// The record's local write counter when the push was built.
  final int sequence;
}
