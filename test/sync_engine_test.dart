import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_remote_adapter.dart';

Future<SyncEngine> buildEngine({
  required MockDatabase cache,
  required FakeRemoteAdapter remote,
  SyncConfig? config,
}) async {
  final engine = SyncEngine()
    ..configure(
      local: cache,
      remote: remote,
      config:
          config ?? SyncConfig(collections: const ['tasks'], clock: fixedNow),
    );
  await engine.init();
  return engine;
}

void main() {
  late MockDatabase cache;
  late FakeRemoteAdapter remote;
  final warnings = <String>[];

  setUp(() {
    cache = MockDatabase();
    remote = FakeRemoteAdapter();
    warnings.clear();
  });

  group('write path', () {
    test('a write is local and dirty, and never waits on the network',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'buy milk'});

      expect(await engine.get('tasks', 'a'), {'title': 'buy milk'});
      expect(remote.pushedBatches, isEmpty);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue);
    });

    test('sync metadata never leaks into the user document', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'buy milk'});

      final stored = (await cache.get('tasks', 'a'))!;
      expect(stored.keys, ['title']);
      expect(stored.containsKey('dirty'), isFalse);
      expect(stored.containsKey('syncedAt'), isFalse);

      await engine.sync();
      final pushed = remote.documents['tasks']!['a']!;
      expect(pushed.containsKey('dirty'), isFalse);
      expect(pushed.containsKey('deleted'), isFalse);
    });
  });

  group('dirty lifecycle', () {
    test('write → dirty, push success → clean with anchor written back',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});

      final report = await engine.sync();
      expect(report.pushed, 1);

      final meta = (await engine.metadata.readRecord('tasks', 'a'))!;
      expect(meta.dirty, isFalse);
      expect(meta.syncedAt, isNotNull);
      expect(meta.remoteAnchor?.version, 1);
      expect(meta.retryCount, 0);
    });

    test('a failed push leaves the record dirty and retryable', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      final report = await engine.sync();

      expect(report.failed, 1);
      final meta = (await engine.metadata.readRecord('tasks', 'a'))!;
      expect(meta.dirty, isTrue);
      expect(meta.retryCount, 1);
      expect(remote.documents['tasks'], anyOf(isNull, isEmpty));
    });

    test('a partly failed push clears dirty per record, not per batch',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.set('tasks', 'b', {'title': 'y'});

      remote.failIds.add('b');
      final report = await engine.sync();

      expect(report.pushed, 1);
      expect(report.failed, 1);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isFalse);
      expect((await engine.metadata.readRecord('tasks', 'b'))!.dirty, isTrue);

      // Only the record that never landed is sent again.
      remote.failIds.clear();
      remote.pushedBatches.clear();
      final retry = await engine.flush();
      expect(retry.pushed, 0, reason: 'backoff still active for b');

      final resumed = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(collections: const ['tasks'], clock: fixedNow),
      );
      final afterRestart = await resumed.flush();
      expect(afterRestart.pushed, 1);
      expect(remote.pushedBatches.single.single.id, 'b');
    });

    test('a record is dropped after maxRetries only if the app says so',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          maxRetries: 2,
          onSyncError: (_) => SyncResolution.dropRecord,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.permanent);
      await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
      expect(await engine.metadata.readRecord('tasks', 'a'), isNull);
    });

    test('without a handler the engine goes quiet instead of hammering',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
            collections: const ['tasks'], maxRetries: 2, clock: fixedNow),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.sync();
      final batchesAfterFirst = remote.pushedBatches.length;

      // Backoff is active — the immediately following pass sends nothing.
      await engine.flush();
      expect(remote.pushedBatches.length, batchesAfterFirst);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue);
    });
  });

  group('serverTS', () {
    test('is re-sent on push so the backend stamps the authoritative time',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {
        'title': 'x',
        'updatedAt': DatabaseRepository.serverTS,
      });

      // The local cache resolved it to device time already.
      final localBefore = (await cache.get('tasks', 'a'))!;
      expect(localBefore['updatedAt'], isA<DateTime>());

      await engine.sync();

      // What went over the wire was the placeholder, not the device time.
      final item = remote.pushedBatches.single.single;
      expect(item.data!['updatedAt'], DatabaseRepository.serverTS);

      // And the server's time was written back into the cached document.
      expect(
        (await engine.get('tasks', 'a'))!['updatedAt'],
        DateTime.utc(2026, 6, 1, 12),
      );
    });

    test('the field list is metadata, not payload', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {
        'title': 'x',
        'updatedAt': DatabaseRepository.serverTS,
      });

      expect(
        (await engine.metadata.readRecord('tasks', 'a'))!.serverTsFields,
        ['updatedAt'],
      );
      expect((await cache.get('tasks', 'a'))!.containsKey('serverTsFields'),
          isFalse);
    });
  });

  group('tombstones', () {
    test('a deleted record is hidden from get, getAll and query', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x', 'done': false});
      await engine.set('tasks', 'b', {'title': 'y', 'done': false});
      await engine.delete('tasks', 'a');

      expect(await engine.get('tasks', 'a'), isNull);
      expect((await engine.getAll('tasks'))!.keys, ['b']);
      expect(
        await engine.query('tasks', where: {'done': false}),
        [
          {'id': 'b', 'title': 'y', 'done': false}
        ],
      );
      expect(await engine.exists('tasks', 'a'), isFalse);
    });

    test('the delete reaches the backend on the next push', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();
      expect(remote.documents['tasks']!.containsKey('a'), isTrue);

      await engine.delete('tasks', 'a');
      final report = await engine.sync();

      expect(report.deletedRemotely, 1);
      expect(remote.documents['tasks']!.containsKey('a'), isFalse);
    });

    test('a confirmed tombstone survives until its retention elapses',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();
      await engine.delete('tasks', 'a');
      await engine.sync();

      // Still there: dropping it early would let a stale device resurrect it.
      final meta = await engine.metadata.readRecord('tasks', 'a');
      expect(meta, isNotNull);
      expect(meta!.deleted, isTrue);
      expect(meta.dirty, isFalse);
    });

    test('an elapsed tombstone is garbage collected', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          tombstoneRetention: Duration.zero,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();
      await engine.delete('tasks', 'a');

      // With zero retention the tombstone is collected in the same pass that
      // confirmed its remote delete.
      final report = await engine.sync();
      expect(report.deletedRemotely, 1);
      expect(report.tombstonesCollected, 1);
      expect(await engine.metadata.readRecord('tasks', 'a'), isNull);
      expect(await cache.get('tasks', 'a'), isNull);
    });

    test(
        'retention is measured from the remote confirmation, not the local '
        'delete', () async {
      final clock = MovableClock(DateTime.utc(2026, 6, 1, 12));
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: clock.now,
          tombstoneRetention: const Duration(days: 7),
          onWarning: warnings.add,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      // Deleted while offline, and the device stays offline far longer than
      // the retention window.
      await engine.delete('tasks', 'a');
      clock.advance(const Duration(days: 30));

      // The delete only reaches the backend now — the protection window for
      // other devices has to start here, not 30 days ago.
      final confirming = await engine.sync();
      expect(confirming.deletedRemotely, 1);
      expect(confirming.tombstonesCollected, 0);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.deleted, isTrue);

      clock.advance(const Duration(days: 8));
      final collecting = await engine.sync();
      expect(collecting.tombstonesCollected, 1);
    });

    test(
        'a confirmed tombstone reappearing in a delete delta is not '
        'collected early', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: fixedNow,
          tombstoneRetention: const Duration(days: 7),
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();
      await engine.delete('tasks', 'a');
      await engine.sync();

      // The backend reports the deletion again in a later delta.
      remote.pendingDeletes.putIfAbsent('tasks', () => []).add('a');
      await engine.sync();

      final meta = await engine.metadata.readRecord('tasks', 'a');
      expect(meta, isNotNull, reason: 'the tombstone must survive its window');
      expect(meta!.deleted, isTrue);
    });

    test('a still-dirty tombstone is never collected', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          tombstoneRetention: Duration.zero,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();
      await engine.delete('tasks', 'a');

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      final report = await engine.sync();

      expect(report.tombstonesCollected, 0);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.deleted, isTrue);
    });
  });

  group('content conflicts', () {
    Future<SyncEngine> conflicted(ConflictPolicy policy) async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          defaultPolicy: policy,
          onWarning: warnings.add,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'local edit'});
      remote.seed(
        'tasks',
        'a',
        {'title': 'remote edit'},
        updatedAt: DateTime.utc(2026, 6, 1, 13),
      );
      return engine;
    }

    test('serverWins discards the local edit', () async {
      final engine = await conflicted(ConflictPolicy.serverWins);
      final report = await engine.sync();

      expect(report.conflicts, 1);
      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
    });

    test('clientWins keeps the local edit and pushes it', () async {
      final engine = await conflicted(ConflictPolicy.clientWins);
      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(remote.documents['tasks']!['a']!['title'], 'local edit');
    });

    test('lastWriteWins lets the newer timestamp decide', () async {
      final engine = await conflicted(ConflictPolicy.lastWriteWins);
      await engine.sync();

      // The remote edit is stamped an hour later than the local write.
      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
    });

    test('custom merge keeps both edits and stays dirty until pushed',
        () async {
      final engine = await conflicted(
        ConflictPolicy.custom(
          (local, remote) => {
            'title': '${local['title']} + ${remote['title']}',
          },
        ),
      );
      await engine.sync();

      expect(
        (await engine.get('tasks', 'a'))!['title'],
        'local edit + remote edit',
      );
      // A merged document exists on neither side, so it had to be pushed.
      expect(remote.documents['tasks']!['a']!['title'],
          'local edit + remote edit');
    });

    test('lastWriteWins without a remote timestamp decides nothing', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onWarning: warnings.add,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'local edit'});
      remote.documents.putIfAbsent('tasks', () => {})['a'] = {
        'title': 'remote edit'
      };
      remote.anchors.putIfAbsent('tasks', () => {})['a'] =
          const RemoteAnchor(version: 9);

      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(warnings.join(), contains('lastWriteWins'));
    });

    test('a clean record is overwritten without counting as a conflict',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'from server'});

      final report = await engine.sync();
      expect(report.conflicts, 0);
      expect(report.pulled, 1);
      expect((await engine.get('tasks', 'a'))!['title'], 'from server');
    });
  });

  group('delete conflicts', () {
    test('local delete vs remote modify: serverWins resurrects the record',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.delete('tasks', 'a');
      remote.seed(
        'tasks',
        'a',
        {'title': 'edited elsewhere'},
        updatedAt: DateTime.utc(2026, 6, 1, 14),
        version: 2,
      );

      await engine.sync();
      expect((await engine.get('tasks', 'a'))!['title'], 'edited elsewhere');
    });

    test('local delete vs remote modify: deleteWins keeps it deleted',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          defaultDeletePolicy: DeleteConflictPolicy.deleteWins,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.delete('tasks', 'a');
      remote.seed('tasks', 'a', {'title': 'edited elsewhere'}, version: 2);

      await engine.sync();
      expect(await engine.get('tasks', 'a'), isNull);
      expect(remote.documents['tasks']!.containsKey('a'), isFalse);
    });

    test('local modify vs remote delete: serverWins removes it locally',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.set('tasks', 'a', {'title': 'local edit'});
      remote.remoteDelete('tasks', 'a');

      await engine.sync();
      expect(await engine.get('tasks', 'a'), isNull);
    });

    test('local modify vs remote delete: modifyWins resurrects it remotely',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          defaultDeletePolicy: DeleteConflictPolicy.modifyWins,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.set('tasks', 'a', {'title': 'local edit'});
      remote.remoteDelete('tasks', 'a');

      await engine.sync();
      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(remote.documents['tasks']!['a']!['title'], 'local edit');
    });

    test('lastWriteWins for deletes warns when it cannot order the two sides',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: fixedNow,
          defaultDeletePolicy: DeleteConflictPolicy.lastWriteWins,
          onWarning: warnings.add,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.set('tasks', 'a', {'title': 'local edit'});
      remote.remoteDelete('tasks', 'a');
      await engine.sync();

      // Nothing was destroyed — but the app is told its policy was inert.
      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(warnings.join(), contains('lastWriteWins cannot order'));
    });

    test('deleted on both sides converges without a conflict', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      await engine.set('tasks', 'a', {'title': 'x'});
      await engine.sync();

      await engine.delete('tasks', 'a');
      remote.remoteDelete('tasks', 'a');

      final report = await engine.sync();
      expect(report.conflicts, 0);
      expect(await engine.get('tasks', 'a'), isNull);
    });
  });

  group('cursor', () {
    test('advances after a completed pull', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'x'});

      final report = await engine.sync();
      expect(report.cursorAdvanced, isTrue);
      expect(
        (await engine.metadata.readCollection('tasks'))!.cursor,
        DateTime.utc(2026, 6, 1, 12),
      );
    });

    test('does not advance when the pull fails midway', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onWarning: warnings.add,
        ),
      );
      remote.seed('tasks', 'a', {'title': 'x'});
      await engine.sync();
      final cursorBefore =
          (await engine.metadata.readCollection('tasks'))!.cursor;

      remote.pullError = const SyncError(SyncErrorKind.transient);
      final report = await engine.sync();

      expect(report.cursorAdvanced, isFalse);
      expect(
        (await engine.metadata.readCollection('tasks'))!.cursor,
        cursorBefore,
      );
    });

    test('a paginated pull advances only after the last page', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.scriptedPages = [
        DeltaResult(
          changed: [
            RemoteRecord(
              id: 'a',
              data: const {'title': 'page 1'},
              anchor: RemoteAnchor(updatedAt: DateTime.utc(2026, 6, 1, 10)),
            ),
          ],
          nextCursor: DateTime.utc(2026, 6, 1, 10),
          hasMore: true,
        ),
        DeltaResult(
          changed: [
            RemoteRecord(
              id: 'b',
              data: const {'title': 'page 2'},
              anchor: RemoteAnchor(updatedAt: DateTime.utc(2026, 6, 1, 11)),
            ),
          ],
          nextCursor: DateTime.utc(2026, 6, 1, 11),
        ),
      ];

      final report = await engine.sync();
      expect(report.pulled, 2);
      expect(
        (await engine.metadata.readCollection('tasks'))!.cursor,
        DateTime.utc(2026, 6, 1, 11),
      );
    });

    test('a boundary record with the cursor timestamp is not dropped',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      final boundary = DateTime.utc(2026, 6, 1, 12);
      remote.scriptedPages = [
        DeltaResult(
          changed: [
            RemoteRecord(
              id: 'a',
              data: const {'title': 'exactly at the cursor'},
              anchor: RemoteAnchor(updatedAt: boundary),
            ),
          ],
          nextCursor: boundary,
        ),
      ];

      await engine.sync();
      expect(
          (await engine.get('tasks', 'a'))!['title'], 'exactly at the cursor');
    });
  });

  group('capability checks', () {
    test('no conflict anchor is a data-loss risk and refuses to start',
        () async {
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: FakeRemoteAdapter(
            capabilities: const SyncCapabilities(supportsDeltaPull: true),
          ),
          config: SyncConfig(collections: const ['tasks'], clock: fixedNow),
        );

      expect(engine.init, throwsA(isA<SyncCapabilityException>()));
    });

    test('the strict default can be overridden to degrade', () async {
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: FakeRemoteAdapter(
            capabilities: const SyncCapabilities(supportsDeltaPull: true),
          ),
          config: SyncConfig(
            collections: const ['tasks'],
            defaultPolicy: ConflictPolicy.serverWins,
            missingConflictAnchor: CapabilityFallback.degrade,
            onWarning: warnings.add,
          ),
        );

      await engine.init();
      expect(engine.isInitialized, isTrue);
      expect(warnings.join(), contains('no conflict anchor'));
    });

    test('missing delta pull only degrades, and warns about the cost',
        () async {
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: FakeRemoteAdapter(
            capabilities: const SyncCapabilities(supportsTimestamps: true),
          ),
          config: SyncConfig(
            collections: const ['tasks'],
            onWarning: warnings.add,
          ),
        );

      await engine.init();
      expect(warnings.join(), contains('full pulls'));
    });

    test('a full pull detects a remote deletion the delta could not report',
        () async {
      final fullPullOnly = FakeRemoteAdapter(
        capabilities: const SyncCapabilities(
          supportsTimestamps: true,
          supportsVersioning: true,
        ),
      );
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: fullPullOnly,
          config: SyncConfig(
            collections: const ['tasks'],
            onWarning: warnings.add,
          ),
        );
      await engine.init();

      fullPullOnly.seed('tasks', 'a', {'title': 'x'});
      await engine.sync();
      expect(await engine.get('tasks', 'a'), isNotNull);

      fullPullOnly.documents['tasks']!.remove('a');
      fullPullOnly.anchors['tasks']!.remove('a');
      final report = await engine.sync();

      expect(report.deletedLocally, 1);
      expect(await engine.get('tasks', 'a'), isNull);
    });

    test('a purely local record is not wiped by a full pull', () async {
      final fullPullOnly = FakeRemoteAdapter(
        capabilities: const SyncCapabilities(supportsTimestamps: true),
      );
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: fullPullOnly,
          config: SyncConfig(
            collections: const ['tasks'],
            onWarning: warnings.add,
          ),
        );
      await engine.init();

      await engine.set('tasks', 'local-only', {'title': 'never pushed'});
      fullPullOnly.forcedPushStatus = PushStatus.failed;
      fullPullOnly.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.sync();

      expect(await engine.get('tasks', 'local-only'), isNotNull);
    });

    test('reserved namespaces cannot be configured as payload collections', () {
      expect(
        () => SyncEngine().configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
              collections: const ['__ds_sync__meta'], clock: fixedNow),
        ),
        throwsArgumentError,
      );
    });
  });

  group('error handling', () {
    test('a named handler takes precedence over the catch-all', () async {
      final seen = <String>[];
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onUnauthorized: (_) {
            seen.add('named');
            return SyncResolution.leaveDirty;
          },
          onSyncError: (_) {
            seen.add('catch-all');
            return SyncResolution.leaveDirty;
          },
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.unauthorized);
      await engine.sync();

      expect(seen, ['named']);
    });

    test('the catch-all handles kinds without a dedicated hook', () async {
      final kinds = <SyncErrorKind>[];
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onSyncError: (context) {
            kinds.add(context.error.kind);
            return null;
          },
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.rateLimited);
      await engine.sync();

      expect(kinds, [SyncErrorKind.rateLimited]);
    });

    test('retryNow clears the backoff so the next pass sends again', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onSyncError: (_) => SyncResolution.retryNow,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.sync();

      final report = await engine.flush();
      expect(report.pushed, 1);
    });

    test('a push conflict stays dirty and is not counted as a failure',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onWarning: warnings.add,
        ),
      );
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.conflict;
      final report = await engine.sync();

      expect(report.failed, 0);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue);
      expect(warnings.join(), contains('conflicted'));
    });

    test('an unreachable backend surfaces as transient via the adapter',
        () async {
      final kinds = <SyncErrorKind>[];
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          onSyncError: (context) {
            kinds.add(context.error.kind);
            return null;
          },
        ),
      );

      remote.pullError = 'socket closed';
      await engine.sync();

      expect(kinds, [SyncErrorKind.transient]);
    });
  });

  group('lifecycle', () {
    test('using the engine before init throws', () async {
      final engine = SyncEngine();
      expect(
        () => engine.set('tasks', 'a', {'title': 'x'}),
        throwsA(isA<SyncNotInitializedException>()),
      );
    });

    test('flush pushes without pulling', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'server-side', {'title': 'not pulled'});
      await engine.set('tasks', 'a', {'title': 'x'});

      final report = await engine.flush();
      expect(report.pushed, 1);
      expect(report.pulled, 0);
      expect(await engine.get('tasks', 'server-side'), isNull);
    });
  });

  group('multi-user isolation', () {
    late SyncEngine engine;

    setUp(() async {
      engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          userScope: UserScope.perDevice,
        ),
      );
    });

    test("B never sees A's records", () async {
      engine.setActiveUser('userA');
      await engine.set('tasks', 'a', {'title': "A's task"});

      engine.setActiveUser('userB');
      expect(await engine.get('tasks', 'a'), isNull);
      expect(await engine.getAll('tasks'), isNull);
    });

    test("A's unpushed change survives a switch to B and back", () async {
      engine.setActiveUser('userA');
      await engine.set('tasks', 'a', {'title': "A's task"});

      engine.setActiveUser('userB');
      await engine.set('tasks', 'a', {'title': "B's task"});

      engine.setActiveUser('userA');
      expect((await engine.get('tasks', 'a'))!['title'], "A's task");
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue);
    });

    test("purging A leaves B's data alone", () async {
      engine.setActiveUser('userA');
      await engine.set('tasks', 'a', {'title': "A's task"});
      engine.setActiveUser('userB');
      await engine.set('tasks', 'b', {'title': "B's task"});

      await engine.purgeUser('userA');

      engine.setActiveUser('userB');
      expect((await engine.get('tasks', 'b'))!['title'], "B's task");
      engine.setActiveUser('userA');
      expect(await engine.getAll('tasks'), isNull);
    });

    test('purgeUser delegates the remote half to the application', () async {
      final purged = <String>[];
      final scoped = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          userScope: UserScope.perDevice,
          onPurgeRemote: (userId) async => purged.add(userId),
        ),
      );
      scoped.setActiveUser('userA');
      await scoped.set('tasks', 'a', {'title': 'x'});

      await scoped.purgeUser('userA', scope: PurgeScope.localAndRemote);
      expect(purged, ['userA']);
    });
  });
}
