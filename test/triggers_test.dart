// Triggers and lifecycle: nothing syncs on its own until a trigger is
// attached explicitly, and stopping the engine must actually stop it.
import 'dart:async';

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

  group('attachConnectivityTrigger', () {
    test('syncs when connectivity reports true', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'x'});

      final online = StreamController<bool>();
      engine.attachConnectivityTrigger(online.stream);

      online.add(true);
      await pumpEventQueue();

      expect(remote.pullCount, 1);
      expect(await engine.get('tasks', 'a'), isNotNull);
      await online.close();
    });

    test('does not sync when connectivity reports false', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'x'});

      final online = StreamController<bool>();
      engine.attachConnectivityTrigger(online.stream);

      online.add(false);
      await pumpEventQueue();

      expect(remote.pullCount, 0);
      expect(await engine.get('tasks', 'a'), isNull);
      await online.close();
    });

    test('attaching a new stream replaces the previous subscription', () async {
      final engine = await buildEngine(cache: cache, remote: remote);

      final first = StreamController<bool>();
      final second = StreamController<bool>();
      engine.attachConnectivityTrigger(first.stream);
      engine.attachConnectivityTrigger(second.stream);

      first.add(true);
      await pumpEventQueue();
      expect(remote.pullCount, 0,
          reason: 'the first stream must no longer be listened to');

      second.add(true);
      await pumpEventQueue();
      expect(remote.pullCount, 1);

      await first.close();
      await second.close();
    });
  });

  group('startPeriodicSync', () {
    test('syncs repeatedly on the configured interval', () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'x'});

      engine.startPeriodicSync(const Duration(milliseconds: 10));

      await Future<void>.delayed(const Duration(milliseconds: 35));
      await pumpEventQueue();

      expect(remote.pullCount, greaterThanOrEqualTo(2),
          reason: 'a single-shot trigger would never fire more than once');

      await engine.dispose();
    });
  });

  group('dispose', () {
    test('cancels both the periodic timer and the connectivity subscription',
        () async {
      final engine = await buildEngine(cache: cache, remote: remote);
      remote.seed('tasks', 'a', {'title': 'x'});

      final online = StreamController<bool>();
      engine.attachConnectivityTrigger(online.stream);
      engine.startPeriodicSync(const Duration(milliseconds: 10));

      await engine.dispose();
      final countAtDispose = remote.pullCount;

      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await pumpEventQueue();

      expect(remote.pullCount, countAtDispose,
          reason: 'a leaked timer or subscription would keep firing after '
              'dispose()');
      await online.close();
    });
  });

  group('syncCollection', () {
    test('syncs only the requested collection, leaving others untouched',
        () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks', 'notes'],
        ),
      );
      remote.seed('tasks', 'a', {'title': 'x'});
      remote.seed('notes', 'b', {'title': 'y'});

      final report = await engine.syncCollection('tasks');

      expect(report.pulled, 1);
      expect(await engine.get('tasks', 'a'), isNotNull);
      expect(await engine.get('notes', 'b'), isNull,
          reason: 'a single-collection sync must not touch other '
              'collections');
    });

    test('a concurrent syncCollection call is skipped, not queued', () async {
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

      final first = engine.syncCollection('tasks');
      final second = engine.syncCollection('tasks');

      final results = await Future.wait([first, second]);
      expect(results[1].pulled, 0,
          reason: 'the second call must be a no-op report, not a second '
              'pass over the same collection');
      expect(warnings.join(), contains('already running'));
    });
  });

  group('concurrent sync()', () {
    test(
        'a second sync() call while one is running is skipped, not run '
        'twice', () async {
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

      final first = engine.sync();
      final second = engine.sync();
      final results = await Future.wait([first, second]);

      expect(remote.pullCount, 1,
          reason: 'the collection must only be pulled once, not once per '
              'overlapping caller');
      expect(results[1].pulled, 0);
      expect(warnings.join(), contains('already running'));
    });
  });

  group('clearActiveUser', () {
    test(
        'clears runtime backoff state without touching persisted dirty '
        'flags', () async {
      final engine = await buildEngine(
        cache: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          userScope: UserScope.perDevice,
        ),
      );
      engine.setActiveUser('userA');
      await engine.set('tasks', 'a', {'title': 'x'});

      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.sync();
      remote.pushedBatches.clear();

      // Backoff is active — an immediate retry would send nothing.
      final beforeClear = await engine.flush();
      expect(beforeClear.pushed, 0);

      engine.clearActiveUser();
      engine.setActiveUser('userA');

      final afterClear = await engine.flush();
      expect(afterClear.pushed, 1,
          reason: 'clearActiveUser() must reset in-memory backoff so the '
              'same user is not punished after a re-login');
    });
  });
}
