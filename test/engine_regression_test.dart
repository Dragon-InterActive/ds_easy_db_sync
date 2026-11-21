import 'dart:async';

import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_remote_adapter.dart';

/// Runs [duringPush] after the backend applied a batch but before the engine
/// sees the results — the moment a push is "on the wire".
class _PausingRemote extends FakeRemoteAdapter {
  _PausingRemote({super.capabilities});

  Future<void> Function()? duringPush;

  @override
  Future<List<PushResult>> pushBatch(List<PushItem> items) async {
    final results = await super.pushBatch(items);
    final hook = duringPush;
    duringPush = null;
    if (hook != null) await hook();
    return results;
  }
}

/// Holds the first pull until [releasePull] is called.
class _BlockingPullRemote extends FakeRemoteAdapter {
  final Completer<void> _gate = Completer<void>();

  void releasePull() => _gate.complete();

  @override
  Future<DeltaResult> pullSince(String collection, Object? cursor) async {
    await _gate.future;
    return super.pullSince(collection, cursor);
  }
}

const _fullPullOnly = SyncCapabilities(
  supportsTimestamps: true,
  supportsVersioning: true,
  supportsBatchWrite: true,
);

Future<SyncEngine> _engine(
  MockDatabase cache,
  SyncRemoteAdapter remote, {
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

  setUp(() => cache = MockDatabase());

  group('full pull with an unchanged remote copy', () {
    test('a local delete is pushed, not reverted (default serverWins)',
        () async {
      final remote = _PausingRemote(capabilities: _fullPullOnly)
        ..seed('tasks', 'a', {'title': 'x'});
      final engine = await _engine(cache, remote);
      await engine.sync();

      await engine.delete('tasks', 'a');
      final report = await engine.sync();

      expect(report.conflicts, 0);
      expect(await engine.get('tasks', 'a'), isNull);
      expect(remote.documents['tasks'], isNot(contains('a')));
    });

    test('a local edit is pushed, not reverted by serverWins', () async {
      final remote = _PausingRemote(capabilities: _fullPullOnly)
        ..seed('tasks', 'a', {'title': 'old'});
      final engine = await _engine(
        cache,
        remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: fixedNow,
          defaultPolicy: ConflictPolicy.serverWins,
        ),
      );
      await engine.sync();

      await engine.update('tasks', 'a', {'title': 'new'});
      final report = await engine.sync();

      expect(report.conflicts, 0);
      expect(await engine.get('tasks', 'a'), {'title': 'new'});
      expect(remote.documents['tasks']!['a'], {'title': 'new'});
    });
  });

  group('writes while a push is on the wire', () {
    test('a newer set stays dirty and is pushed next time', () async {
      final remote = _PausingRemote();
      final engine = await _engine(cache, remote);
      await engine.set('tasks', 'a', {'v': 1});

      remote.duringPush = () => engine.set('tasks', 'a', {'v': 2});
      await engine.sync();

      final meta = (await engine.metadata.readRecord('tasks', 'a'))!;
      expect(meta.dirty, isTrue);
      expect(meta.remoteAnchor?.version, 1);

      await engine.sync();
      expect(remote.documents['tasks']!['a'], {'v': 2});
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isFalse);
    });

    test('a delete during the push still reaches the backend', () async {
      final remote = _PausingRemote();
      final engine = await _engine(cache, remote);
      await engine.set('tasks', 'a', {'v': 1});

      remote.duringPush = () => engine.delete('tasks', 'a');
      await engine.sync();

      final meta = (await engine.metadata.readRecord('tasks', 'a'))!;
      expect(meta.deleted, isTrue);
      expect(meta.dirty, isTrue);

      await engine.sync();
      expect(remote.documents['tasks'], isNot(contains('a')));
    });
  });

  test('update on a tombstone does not bring the old fields back', () async {
    final engine = await _engine(cache, FakeRemoteAdapter());
    await engine.set('tasks', 'a', {'title': 'x', 'secret': 1});
    await engine.delete('tasks', 'a');

    await engine.update('tasks', 'a', {'title': 'y'});

    expect(await engine.get('tasks', 'a'), {'title': 'y'});
  });

  test('a serverTS field is stamped once, not again on every later update',
      () async {
    final clock = MovableClock(fixedNow());
    final remote = FakeRemoteAdapter(serverTime: clock.now);
    final engine = await _engine(
      cache,
      remote,
      config: SyncConfig(collections: const ['tasks'], clock: clock.now),
    );

    await engine.set('tasks', 'a', {
      'createdAt': DatabaseRepository.serverTS,
      'n': 1,
    });
    await engine.sync();
    final created = remote.documents['tasks']!['a']!['createdAt'];

    clock.advance(const Duration(hours: 1));
    await engine.update('tasks', 'a', {'n': 2});
    await engine.sync();

    expect(remote.documents['tasks']!['a']!['createdAt'], created);
    expect(remote.documents['tasks']!['a']!['n'], 2);
  });

  test('purgeUser in UserScope.single also clears metadata and cursor',
      () async {
    final remote = FakeRemoteAdapter()..seed('tasks', 'a', {'title': 'x'});
    final engine = await _engine(cache, remote);
    await engine.sync();
    await engine.set('tasks', 'b', {'title': 'local'});

    await engine.purgeUser('whoever');

    expect(await engine.metadata.readRecord('tasks', 'a'), isNull);
    expect(await engine.metadata.readRecord('tasks', 'b'), isNull);
    expect(await engine.metadata.readCollection('tasks'), isNull);

    // Without the old cursor the next pull restores what the server has.
    await engine.sync();
    expect(await engine.get('tasks', 'a'), {'title': 'x'});
    expect(await engine.get('tasks', 'b'), isNull);
  });

  test('flush waits for a running pass instead of running beside it', () async {
    final remote = _BlockingPullRemote();
    final engine = await _engine(cache, remote);
    await engine.set('tasks', 'a', {'v': 1});

    final sync = engine.sync();
    var flushed = false;
    final flush = engine.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);

    expect(flushed, isFalse, reason: 'flush must not run during the pull');
    expect(remote.pushedBatches, isEmpty);

    remote.releasePull();
    await Future.wait([sync, flush]);
    expect(remote.pushedBatches.expand((batch) => batch), hasLength(1));
  });

  group('switching users during a pass', () {
    Future<SyncEngine> perDevice(SyncRemoteAdapter remote) async {
      final engine = await _engine(
        cache,
        remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: fixedNow,
          userScope: UserScope.perDevice,
        ),
      );
      engine.setActiveUser('userA');
      return engine;
    }

    test('setActiveUser and clearActiveUser throw while a pass runs', () async {
      final remote = _BlockingPullRemote();
      final engine = await perDevice(remote);

      final sync = engine.sync();
      expect(engine.isSyncing, isTrue);
      expect(() => engine.setActiveUser('userB'),
          throwsA(isA<SyncBusyException>()));
      expect(engine.clearActiveUser, throwsA(isA<SyncBusyException>()));

      remote.releasePull();
      await sync;
      expect(engine.isSyncing, isFalse);
      engine.setActiveUser('userB');
    });

    test('after whenIdle() the switch is safe', () async {
      final remote = _BlockingPullRemote();
      final engine = await perDevice(remote);
      await engine.set('tasks', 'a', {'v': 1});

      unawaited(engine.sync());
      final idle = engine.whenIdle();
      remote.releasePull();
      await idle;

      engine.setActiveUser('userB');
      expect(await engine.get('tasks', 'a'), isNull);
      engine.setActiveUser('userA');
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isFalse);
    });
  });
}
