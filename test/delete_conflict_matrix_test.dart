// Full delete-conflict matrix: every DeleteConflictPolicy against both
// conflict directions. Each test states what would silently break in
// production (a resurrected record, a lost edit, a lost delete) if the
// engine picked the wrong outcome or shipped it to the wrong side.
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_remote_adapter.dart';

void main() {
  late MockDatabase cache;
  late FakeRemoteAdapter remote;
  final warnings = <String>[];

  setUp(() {
    cache = MockDatabase();
    remote = FakeRemoteAdapter();
    warnings.clear();
  });

  Future<SyncEngine> engineWith(DeleteConflictPolicy policy) async {
    final engine = SyncEngine()
      ..configure(
        local: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['tasks'],
          defaultDeletePolicy: policy,
          onWarning: warnings.add,
        ),
      );
    await engine.init();
    return engine;
  }

  /// Direction A: the record is deleted locally while the remote holds a
  /// newer modification.
  Future<SyncEngine> directionA(DeleteConflictPolicy policy) async {
    final engine = await engineWith(policy);
    await engine.set('tasks', 'a', {'title': 'original'});
    await engine.sync();

    await engine.delete('tasks', 'a');
    remote.seed(
      'tasks',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 14),
      version: 2,
    );
    return engine;
  }

  /// Direction B: the record is modified locally while the remote deleted
  /// it. A remote delete carries no timestamp, which is the documented
  /// limitation exercised explicitly below.
  Future<SyncEngine> directionB(DeleteConflictPolicy policy) async {
    final engine = await engineWith(policy);
    await engine.set('tasks', 'a', {'title': 'original'});
    await engine.sync();

    await engine.set('tasks', 'a', {'title': 'local edit'});
    remote.remoteDelete('tasks', 'a');
    return engine;
  }

  group('deleteWins — the record dies on both sides regardless of who edited',
      () {
    test('direction A: local delete beats a newer remote modification',
        () async {
      final engine = await directionA(DeleteConflictPolicy.deleteWins);
      await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
      expect(remote.documents['tasks']!.containsKey('a'), isFalse,
          reason: 'the delete must reach the backend, not just stay local');
    });

    test('direction B: local modification is discarded, nothing is pushed',
        () async {
      final engine = await directionB(DeleteConflictPolicy.deleteWins);
      final report = await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
      expect(await engine.metadata.readRecord('tasks', 'a'), isNull,
          reason: 'remote already deleted it — nothing left to push');
      expect(report.deletedLocally, 1);
    });
  });

  group('modifyWins — the modification always resurrects the record', () {
    test('direction A: local delete is overridden by the remote edit',
        () async {
      final engine = await directionA(DeleteConflictPolicy.modifyWins);

      // Isolate the resolution outcome from the same-pass push: force the
      // push to fail so "the delete side has to learn the record survived"
      // (dirty stays true) can be observed independently of a successful
      // re-push clearing it again within the same sync() call.
      remote.forcedPushStatus = PushStatus.failed;
      remote.forcedPushError = const SyncError(SyncErrorKind.transient);
      await engine.sync();

      // The surviving document for a local-delete conflict is the remote
      // edit — that is what modifyWins restores locally.
      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
      expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isTrue,
          reason: 'the delete side has to learn the record survived');
    });

    test('direction B: local edit resurrects the record remotely', () async {
      final engine = await directionB(DeleteConflictPolicy.modifyWins);
      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(remote.documents['tasks']!['a']!['title'], 'local edit');
    });
  });

  group(
      'clientWins — whatever the local device did wins, independent of '
      'who deleted', () {
    test('direction A: local delete wins even though remote only modified',
        () async {
      final engine = await directionA(DeleteConflictPolicy.clientWins);
      await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
      expect(remote.documents['tasks']!.containsKey('a'), isFalse);
    });

    test(
        'direction B: local modification resurrects a remotely deleted '
        'record', () async {
      final engine = await directionB(DeleteConflictPolicy.clientWins);
      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
      expect(remote.documents['tasks']!['a']!['title'], 'local edit');
    });
  });

  group('serverWins — whatever the remote side did wins (the default)', () {
    test(
        'direction A: remote modification resurrects a locally deleted '
        'record', () async {
      final engine = await directionA(DeleteConflictPolicy.serverWins);
      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
    });

    test('direction B: remote delete wins, the local edit is lost', () async {
      final engine = await directionB(DeleteConflictPolicy.serverWins);
      await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
    });
  });

  group(
      'lastWriteWins — orders by timestamp where one exists, and is '
      'explicit about the direction where it cannot', () {
    test(
        'direction A: both sides carry timestamps, so the later one wins '
        '(remote edit is newer)', () async {
      final engine = await directionA(DeleteConflictPolicy.lastWriteWins);
      await engine.sync();

      // The local delete happened at fixedNow(); the remote edit is seeded
      // two hours later, so the modification survives.
      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
      expect(warnings, isEmpty,
          reason: 'both timestamps existed — the policy should not warn');
    });

    test(
        'direction A: an older remote modification loses to a newer local '
        'delete', () async {
      final engine = await engineWith(DeleteConflictPolicy.lastWriteWins);
      await engine.set('tasks', 'a', {'title': 'original'});
      await engine.sync();

      await engine.delete('tasks', 'a');
      remote.seed(
        'tasks',
        'a',
        {'title': 'stale remote edit'},
        updatedAt: DateTime.utc(2026, 6, 1, 10), // before the local delete
        version: 2,
      );
      await engine.sync();

      expect(await engine.get('tasks', 'a'), isNull);
      expect(remote.documents['tasks']!.containsKey('a'), isFalse);
    });

    test(
        'direction B: a remote delete carries no timestamp, so the '
        'modification is kept and a warning is emitted — this is the '
        'documented limitation, not correct ordering', () async {
      final engine = await directionB(DeleteConflictPolicy.lastWriteWins);
      await engine.sync();

      expect((await engine.get('tasks', 'a'))!['title'], 'local edit',
          reason: 'nothing is destroyed when ordering is impossible');
      expect(remote.documents['tasks']!['a']!['title'], 'local edit');
      expect(
        warnings.join(),
        contains('lastWriteWins cannot order'),
        reason: 'the app must be told its configured ordering was inert',
      );
    });
  });

  group(
      'custom — the application decides with explicit delete-conflict '
      'context', () {
    test(
        'direction A: the resolver sees localDeleteRemoteModify and the '
        'remote copy as the surviving document', () async {
      DeleteConflictContext? seen;
      final engine = await directionA(
        DeleteConflictPolicy.custom((context) {
          seen = context;
          return DeleteConflictOutcome.keep(context.survivingDocument);
        }),
      );
      await engine.sync();

      expect(seen, isNotNull);
      expect(seen!.direction, DeleteConflictDirection.localDeleteRemoteModify);
      expect(seen!.survivingDocument['title'], 'remote edit');
      expect((await engine.get('tasks', 'a'))!['title'], 'remote edit');
    });

    test(
        'direction B: the resolver sees localModifyRemoteDelete and can '
        'force the delete despite the local edit', () async {
      DeleteConflictContext? seen;
      final engine = await directionB(
        DeleteConflictPolicy.custom((context) {
          seen = context;
          return DeleteConflictOutcome.delete;
        }),
      );
      await engine.sync();

      expect(seen, isNotNull);
      expect(seen!.direction, DeleteConflictDirection.localModifyRemoteDelete);
      expect(seen!.survivingDocument['title'], 'local edit');
      expect(await engine.get('tasks', 'a'), isNull,
          reason: 'the custom resolver chose delete over the local edit');
    });
  });
}
