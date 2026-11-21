// Batching and backoff — the sharp edges that only show up under many
// records or many consecutive failures, never in a single happy-path push.
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_remote_adapter.dart';

void main() {
  late MockDatabase cache;
  late FakeRemoteAdapter remote;

  setUp(() {
    cache = MockDatabase();
    remote = FakeRemoteAdapter();
  });

  group('pushBatchSize', () {
    test(
        'splits a large push into several pushBatch calls, each applied '
        'per record', () async {
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: fixedNow,
            collections: const ['tasks'],
            pushBatchSize: 2,
          ),
        );
      await engine.init();

      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        await engine.set('tasks', id, {'title': id});
      }

      final report = await engine.sync();

      expect(report.pushed, 5);
      expect(remote.pushedBatches.length, 3,
          reason: '5 records at a batch size of 2 must be 2 + 2 + 1 calls');
      expect(remote.pushedBatches.map((b) => b.length), [2, 2, 1]);

      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        expect((await engine.metadata.readRecord('tasks', id))!.dirty, isFalse,
            reason: 'every record must be cleared individually, not just '
                'the batch as a whole');
      }
    });

    test('a failure in one batch does not block records in another batch',
        () async {
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: fixedNow,
            collections: const ['tasks'],
            pushBatchSize: 1,
          ),
        );
      await engine.init();

      await engine.set('tasks', 'a', {'title': 'a'});
      await engine.set('tasks', 'b', {'title': 'b'});
      remote.failIds.add('a');

      final report = await engine.sync();

      expect(report.pushed, 1);
      expect(report.failed, 1);
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue);
      expect((await engine.metadata.readRecord('tasks', 'b'))!.dirty, isFalse);
    });
  });

  group('backoff', () {
    test('rateLimited backs off longer than a plain transient failure',
        () async {
      final clockA = MovableClock(DateTime.utc(2026, 6, 1, 12));
      final engineA = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: clockA.now,
            collections: const ['transientTasks'],
            initialBackoff: const Duration(seconds: 5),
            rateLimitBackoff: const Duration(seconds: 30),
            maxBackoff: const Duration(minutes: 10),
          ),
        );
      await engineA.init();
      await engineA.set('transientTasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engineA.sync();

      // Just short of the transient backoff: nothing retried yet.
      clockA.advance(const Duration(seconds: 4));
      expect((await engineA.flush()).pushed, 0);
      // Past it: the transient record retries and succeeds.
      clockA.advance(const Duration(seconds: 2));
      expect((await engineA.flush()).pushed, 1);

      final cacheB = MockDatabase();
      final remoteB = FakeRemoteAdapter();
      final clockB = MovableClock(DateTime.utc(2026, 6, 1, 12));
      final engineB = SyncEngine()
        ..configure(
          local: cacheB,
          remote: remoteB,
          config: SyncConfig(
            clock: clockB.now,
            collections: const ['rateLimitedTasks'],
            initialBackoff: const Duration(seconds: 5),
            rateLimitBackoff: const Duration(seconds: 30),
            maxBackoff: const Duration(minutes: 10),
          ),
        );
      await engineB.init();
      await engineB.set('rateLimitedTasks', 'b', {'title': 'x'});

      remoteB.forcedPushStatus = PushStatus.failed;
      remoteB.forcedPushError = const SyncError(SyncErrorKind.rateLimited);
      await engineB.sync();

      // The same 6 seconds that cleared the transient case must still be
      // backing off for a rate-limited one.
      clockB.advance(const Duration(seconds: 6));
      expect((await engineB.flush()).pushed, 0,
          reason: 'rateLimited must use the longer backoff, not the '
              'transient one');
      clockB.advance(const Duration(seconds: 25));
      expect((await engineB.flush()).pushed, 1);
    });

    test('the backoff delay doubles per attempt and is capped by maxBackoff',
        () async {
      final clock = MovableClock(DateTime.utc(2026, 6, 1, 12));
      final engine = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: clock.now,
            collections: const ['tasks'],
            initialBackoff: const Duration(seconds: 1),
            maxBackoff: const Duration(seconds: 3),
            maxRetries: 10,
          ),
        );
      await engine.init();
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);

      // Attempt 1 fails: backoff = initialBackoff * 2^0 = 1s.
      await engine.sync();
      expect((await engine.metadata.readRecord('tasks', 'a'))!.retryCount, 1);

      clock.advance(const Duration(milliseconds: 999));
      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      expect((await engine.flush()).pushed, 0);
      clock.advance(const Duration(milliseconds: 1));
      // Attempt 2 fails: backoff = initialBackoff * 2^1 = 2s.
      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.flush();
      expect((await engine.metadata.readRecord('tasks', 'a'))!.retryCount, 2);

      clock.advance(const Duration(milliseconds: 1999));
      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      expect((await engine.flush()).pushed, 0,
          reason: 'attempt 2 must wait out 2s, not the 1s attempt 1 used');
      clock.advance(const Duration(milliseconds: 1));
      // Attempt 3 fails: uncapped backoff would be 4s, but maxBackoff caps
      // it at 3s.
      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.flush();
      expect((await engine.metadata.readRecord('tasks', 'a'))!.retryCount, 3);

      clock.advance(const Duration(milliseconds: 2999));
      expect((await engine.flush()).pushed, 0,
          reason: 'still within the capped 3s window');
      clock.advance(const Duration(milliseconds: 1));
      expect((await engine.flush()).pushed, 1,
          reason: 'the cap must be exactly maxBackoff, not the uncapped 4s '
              'the doubling formula would otherwise demand');
    });

    test(
        'retryCount survives an engine restart, but backoff timing does '
        'not', () async {
      final engineBeforeRestart = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: fixedNow,
            collections: const ['tasks'],
            initialBackoff: const Duration(hours: 1),
          ),
        );
      await engineBeforeRestart.init();
      await engineBeforeRestart.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engineBeforeRestart.sync();

      final metaBefore =
          await engineBeforeRestart.metadata.readRecord('tasks', 'a');
      expect(metaBefore!.retryCount, 1,
          reason: 'the give-up counter must be persisted');

      // Simulate an app restart: a fresh SyncEngine, same cache and clock,
      // no time has passed. The 1-hour backoff would still be active if it
      // were persisted runtime state — it must not be.
      final engineAfterRestart = SyncEngine()
        ..configure(
          local: cache,
          remote: remote,
          config: SyncConfig(
            clock: fixedNow,
            collections: const ['tasks'],
            initialBackoff: const Duration(hours: 1),
          ),
        );
      await engineAfterRestart.init();

      final metaAfter =
          await engineAfterRestart.metadata.readRecord('tasks', 'a');
      expect(metaAfter!.retryCount, 1,
          reason: 'retryCount must survive the restart from persisted meta');

      final report = await engineAfterRestart.flush();
      expect(report.pushed, 1,
          reason: 'backoff timing lives only in memory, so a fresh engine '
              'must not still be waiting out the previous instance\'s '
              'in-flight backoff');
    });
  });
}
