import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

RecordMeta _meta(
  String collection,
  String docId, {
  required String userId,
  bool dirty = false,
  bool deleted = false,
  DateTime? localUpdatedAt,
  DateTime? syncedAt,
}) {
  return RecordMeta(
    userId: userId,
    collection: collection,
    docId: docId,
    dirty: dirty,
    deleted: deleted,
    localUpdatedAt: localUpdatedAt ?? DateTime.utc(2026, 1, 1),
    syncedAt: syncedAt,
  );
}

void main() {
  group('single-user scope', () {
    late MockDatabase cache;
    late MetadataStore store;

    setUp(() {
      cache = MockDatabase();
      store = MetadataStore(repository: cache);
    });

    test('metadata never lands in the payload namespace', () async {
      await store.writeRecord(
        _meta('tasks', 'a', userId: SyncKeys.singleUserId, dirty: true),
      );

      expect(await cache.getAll('tasks'), isNull);
      expect(await cache.getAll(SyncKeys.metaNamespace), isNotNull);
    });

    test('round-trips a record through storage', () async {
      final written = RecordMeta(
        userId: SyncKeys.singleUserId,
        collection: 'tasks',
        docId: 'a',
        dirty: true,
        localUpdatedAt: DateTime.utc(2026, 3, 1, 12),
        syncedAt: DateTime.utc(2026, 3, 1, 11),
        remoteAnchor: RemoteAnchor(
          version: 7,
          updatedAt: DateTime.utc(2026, 3, 1, 11),
        ),
        retryCount: 2,
      );
      await store.writeRecord(written);

      final read = await store.readRecord('tasks', 'a');
      expect(read, isNotNull);
      expect(read!.dirty, isTrue);
      expect(read.localUpdatedAt, DateTime.utc(2026, 3, 1, 12));
      expect(read.syncedAt, DateTime.utc(2026, 3, 1, 11));
      expect(read.remoteAnchor?.version, 7);
      expect(read.remoteAnchor?.updatedAt, DateTime.utc(2026, 3, 1, 11));
      expect(read.retryCount, 2);
    });

    test('persists only primitive values, so Hive and SQLite agree', () async {
      await store.writeRecord(
        RecordMeta(
          userId: SyncKeys.singleUserId,
          collection: 'tasks',
          docId: 'a',
          localUpdatedAt: DateTime.utc(2026),
          remoteAnchor: RemoteAnchor(updatedAt: DateTime.utc(2026)),
        ),
      );

      final raw = (await cache.getAll(SyncKeys.metaNamespace))!.values.single
          as Map<String, dynamic>;
      expect(raw['localUpdatedAt'], DateTime.utc(2026).microsecondsSinceEpoch);
      expect(
        (raw['remoteAnchor'] as Map<String, dynamic>)['updatedAt'],
        isA<int>(),
      );
      expect(raw['dirty'], isA<bool>());
    });

    test('dirty query returns changes and tombstones, not clean records',
        () async {
      await store.writeRecord(
        _meta('tasks', 'clean', userId: SyncKeys.singleUserId),
      );
      await store.writeRecord(
        _meta('tasks', 'changed', userId: SyncKeys.singleUserId, dirty: true),
      );
      await store.writeRecord(
        _meta('tasks', 'gone',
            userId: SyncKeys.singleUserId, dirty: true, deleted: true),
      );

      final dirty = await store.dirtyRecords();
      expect(dirty.map((m) => m.docId).toSet(), {'changed', 'gone'});
    });

    test('dirty query can be scoped to one collection', () async {
      await store.writeRecord(
        _meta('tasks', 'a', userId: SyncKeys.singleUserId, dirty: true),
      );
      await store.writeRecord(
        _meta('notes', 'b', userId: SyncKeys.singleUserId, dirty: true),
      );

      final dirty = await store.dirtyRecords(collection: 'notes');
      expect(dirty.single.docId, 'b');
    });

    test('only a confirmed tombstone past its window is collectable', () async {
      final old = DateTime.utc(2020);
      // Delete not yet pushed — collecting it would resurrect the record.
      await store.writeRecord(
        _meta('tasks', 'pending',
            userId: SyncKeys.singleUserId,
            dirty: true,
            deleted: true,
            localUpdatedAt: old),
      );
      // Deleted long ago, but the backend only confirmed it recently: the
      // retention window runs from the confirmation, so it is not due yet.
      await store.writeRecord(
        _meta('tasks', 'just-confirmed',
            userId: SyncKeys.singleUserId,
            deleted: true,
            localUpdatedAt: old,
            syncedAt: DateTime.utc(2026, 6)),
      );
      await store.writeRecord(
        _meta('tasks', 'confirmed',
            userId: SyncKeys.singleUserId,
            deleted: true,
            localUpdatedAt: old,
            syncedAt: DateTime.utc(2021)),
      );

      final collectable = await store.collectableTombstones(DateTime.utc(2026));
      expect(collectable.map((m) => m.docId), ['confirmed']);
    });

    test('cursor round-trips and can be reset to force a full pull', () async {
      await store.advanceCursor('tasks', DateTime.utc(2026, 5, 1));
      expect(
        (await store.readCollection('tasks'))!.cursor,
        DateTime.utc(2026, 5, 1),
      );

      await store.advanceCursor('tasks', null);
      expect((await store.readCollection('tasks'))!.cursor, isNull);
    });

    test('an opaque cursor may be a string or an int', () async {
      await store.advanceCursor('tasks', 'page-token-42');
      expect((await store.readCollection('tasks'))!.cursor, 'page-token-42');

      await store.advanceCursor('notes', 99);
      expect((await store.readCollection('notes'))!.cursor, 99);
    });

    test('a non-persistable cursor is rejected instead of silently mangled',
        () async {
      expect(
        () => store.advanceCursor('tasks', <String>['not', 'primitive']),
        throwsArgumentError,
      );
    });

    test('a corrupt entry reads as "no metadata" instead of throwing',
        () async {
      await cache.set(SyncKeys.metaNamespace, 'tasks:a', {'garbage': true});
      expect(await store.readRecord('tasks', 'a'), isNull);
    });
  });

  group('per-device scope', () {
    late MockDatabase cache;
    late MetadataStore store;

    setUp(() {
      cache = MockDatabase();
      store = MetadataStore(repository: cache, scope: UserScope.perDevice);
    });

    test('refuses to touch metadata without an active user', () async {
      expect(store.hasActiveUser, isFalse);
      expect(() => store.readRecord('tasks', 'a'), throwsStateError);
    });

    test("user B never sees user A's dirty state", () async {
      store.setActiveUser('userA');
      await store.writeRecord(
        _meta('tasks', 'a', userId: 'userA', dirty: true),
      );

      store.setActiveUser('userB');
      expect(await store.dirtyRecords(), isEmpty);
      expect(await store.readRecord('tasks', 'a'), isNull);
    });

    test("A's unpushed change survives a switch to B and back", () async {
      store.setActiveUser('userA');
      await store.writeRecord(
        _meta('tasks', 'a', userId: 'userA', dirty: true),
      );

      store.setActiveUser('userB');
      await store.writeRecord(
        _meta('tasks', 'a', userId: 'userB', dirty: true),
      );

      store.setActiveUser('userA');
      final dirty = await store.dirtyRecords();
      expect(dirty.single.userId, 'userA');
    });

    test('same doc id in both users produces distinct keys', () async {
      store.setActiveUser('userA');
      await store.writeRecord(_meta('tasks', 'a', userId: 'userA'));
      store.setActiveUser('userB');
      await store.writeRecord(_meta('tasks', 'a', userId: 'userB'));

      expect((await cache.getAll(SyncKeys.metaNamespace))!.length, 2);
    });

    test("purging A leaves B's metadata intact", () async {
      store.setActiveUser('userA');
      await store.writeRecord(_meta('tasks', 'a', userId: 'userA'));
      await store.advanceCursor('tasks', 'cursor-a');
      store.setActiveUser('userB');
      await store.writeRecord(_meta('tasks', 'b', userId: 'userB'));
      await store.advanceCursor('tasks', 'cursor-b');

      await store.purgeUser('userA');

      expect((await store.readRecord('tasks', 'b'))!.userId, 'userB');
      expect((await store.readCollection('tasks'))!.cursor, 'cursor-b');
      store.setActiveUser('userA');
      expect(await store.readRecord('tasks', 'a'), isNull);
      expect(await store.readCollection('tasks'), isNull);
    });
  });

  group('SyncKeys', () {
    test('single scope carries no user segment', () {
      expect(
        SyncKeys.recordKey(
          userId: SyncKeys.singleUserId,
          collection: 'tasks',
          docId: 'a',
          scope: UserScope.single,
        ),
        'tasks:a',
      );
    });

    test('a separator inside a segment cannot forge another key', () {
      final withColon = SyncKeys.recordKey(
        userId: 'u',
        collection: 'tasks:extra',
        docId: 'a',
        scope: UserScope.perDevice,
      );
      final plain = SyncKeys.recordKey(
        userId: 'u',
        collection: 'tasks',
        docId: 'extra:a',
        scope: UserScope.perDevice,
      );
      expect(withColon, isNot(plain));
    });

    test('reserved namespaces are recognised', () {
      expect(SyncKeys.isReserved(SyncKeys.metaNamespace), isTrue);
      expect(SyncKeys.isReserved(SyncKeys.cursorNamespace), isTrue);
      expect(SyncKeys.isReserved('tasks'), isFalse);
    });
  });

  group('SyncRuntimeState', () {
    test('backoff and in-flight markers gate eligibility', () {
      final state = SyncRuntimeState();
      final now = DateTime.utc(2026, 6, 1, 12);

      expect(state.isEligible('tasks:a', now), isTrue);

      state.setNextRetry('tasks:a', now.add(const Duration(minutes: 5)));
      expect(state.isEligible('tasks:a', now), isFalse);
      expect(
        state.isEligible('tasks:a', now.add(const Duration(minutes: 6))),
        isTrue,
      );

      state.clearNextRetry('tasks:a');
      state.markInFlight('tasks:a');
      expect(state.isEligible('tasks:a', now), isFalse);
      state.clearInFlight('tasks:a');
      expect(state.isEligible('tasks:a', now), isTrue);
    });
  });
}
