// A self-contained walk-through of the engine.
//
// In an app, `local` is usually `HiveDatabase()` from ds_easy_db_hive and
// `remote` a `FirestoreSyncAdapter()` from ds_easy_db_firestore. Here an
// in-memory cache and a tiny in-memory backend keep the example runnable
// without any setup.
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter/foundation.dart';

Future<void> main() async {
  final backend = InMemoryBackend();
  final sync = SyncEngine()
    ..configure(
      local: MockDatabase(),
      remote: backend,
      config: SyncConfig(
        collections: const ['tasks'],
        // A shopping list tolerates "newest edit wins".
        defaultPolicy: ConflictPolicy.lastWriteWins,
        onWarning: (message) => debugPrint('sync: $message'),
      ),
    );
  await sync.init();

  // Local writes return at once and are pushed on the next pass.
  await sync.set('tasks', 'milk', {
    'title': 'Buy milk',
    'done': false,
    'createdAt': DatabaseRepository.serverTS,
  });
  await sync.set('tasks', 'bread', {'title': 'Buy bread', 'done': false});
  await sync.delete('tasks', 'bread'); // hidden from reads right away

  final open = await sync.query('tasks', where: {'done': false});
  debugPrint('open tasks: $open');

  final report = await sync.sync();
  debugPrint('$report');
  debugPrint('backend now holds: ${backend.documents}');
}

/// A minimal backend that keeps documents in memory and versions every write.
class InMemoryBackend implements SyncRemoteAdapter {
  /// collection -> id -> document.
  final Map<String, Map<String, Map<String, dynamic>>> documents = {};
  final Map<String, Map<String, RemoteAnchor>> _anchors = {};

  @override
  SyncCapabilities get capabilities => const SyncCapabilities(
        supportsVersioning: true,
        supportsTimestamps: true,
        supportsBatchWrite: true,
      );

  @override
  SyncError mapError(Object error, StackTrace stackTrace) =>
      SyncError(SyncErrorKind.transient, cause: error, stackTrace: stackTrace);

  @override
  Future<DeltaResult> pullSince(String collection, Object? cursor) async {
    // No delta support: the engine runs full pulls and diffs them itself.
    return DeltaResult(
      changed: [
        for (final entry in (documents[collection] ?? const {}).entries)
          RemoteRecord(
            id: entry.key,
            data: Map<String, dynamic>.from(entry.value),
            anchor: _anchors[collection]![entry.key]!,
          ),
      ],
    );
  }

  @override
  Future<List<PushResult>> pushBatch(List<PushItem> items) async {
    final now = DateTime.now().toUtc();
    return [
      for (final item in items) _apply(item, now),
    ];
  }

  PushResult _apply(PushItem item, DateTime now) {
    final docs = documents.putIfAbsent(item.collection, () => {});
    final anchors = _anchors.putIfAbsent(item.collection, () => {});
    if (item.isDelete) {
      docs.remove(item.id);
      anchors.remove(item.id);
      return PushResult(id: item.id, status: PushStatus.success);
    }
    docs[item.id] = {
      for (final entry in item.data!.entries)
        entry.key:
            entry.value == DatabaseRepository.serverTS ? now : entry.value,
    };
    final anchor = RemoteAnchor(
      version: (anchors[item.id]?.version ?? 0) + 1,
      updatedAt: now,
    );
    anchors[item.id] = anchor;
    return PushResult(
        id: item.id, status: PushStatus.success, newAnchor: anchor);
  }
}
