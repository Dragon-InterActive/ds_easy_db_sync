import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_remote_adapter.dart';

/// When a policy cannot decide, the engine must not decide either.
///
/// Both fallback paths document "the local copy was kept and stays dirty; no
/// edit was discarded". That promise only holds if the undecided record is
/// also kept out of the push — otherwise the very next push sends the local
/// copy over the remote one, which is a silent `clientWins`.
void main() {
  late MockDatabase cache;
  late FakeRemoteAdapter remote;
  final warnings = <String>[];

  setUp(() {
    cache = MockDatabase();
    remote = FakeRemoteAdapter();
    warnings.clear();
  });

  Future<SyncEngine> engineWith(ConflictPolicy policy) async {
    final engine = SyncEngine()
      ..configure(
        local: cache,
        remote: remote,
        config: SyncConfig(
          collections: const ['tasks'],
          clock: fixedNow,
          defaultPolicy: policy,
          onWarning: warnings.add,
        ),
      );
    await engine.init();
    return engine;
  }

  test('an undecidable three-way merge does not overwrite the remote edit',
      () async {
    final engine = await engineWith(
      ConflictPolicy.customThreeWay((base, local, remote) => local),
    );

    // A record that exists remotely and was edited locally, with no base copy
    // stored yet — the documented fallback case.
    await engine.set('tasks', 'a', {'title': 'local edit'});
    remote.seed(
      'tasks',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 13),
      version: 2,
    );

    await engine.sync();

    expect(warnings.join(), contains('three-way merge'));
    expect(
      remote.documents['tasks']!['a']!['title'],
      'remote edit',
      reason: 'an unresolved conflict must not push the local copy over the '
          'remote edit — that would be a silent clientWins',
    );
  });

  test(
      'lastWriteWins without a remote timestamp does not overwrite the '
      'remote edit', () async {
    final engine = await engineWith(ConflictPolicy.lastWriteWins);

    await engine.set('tasks', 'a', {'title': 'local edit'});
    // A remote record with no timestamp at all: nothing to order against.
    remote.documents.putIfAbsent('tasks', () => {})['a'] = {
      'title': 'remote edit'
    };
    remote.anchors.putIfAbsent('tasks', () => {})['a'] =
        const RemoteAnchor(version: 9);

    await engine.sync();

    expect(warnings.join(), contains('lastWriteWins'));
    expect(
      remote.documents['tasks']!['a']!['title'],
      'remote edit',
      reason: 'the local copy was kept locally, but pushing it would discard '
          'the remote edit the policy could not order against',
    );
  });

  test('an undecided record is offered again on the next pull', () async {
    final engine = await engineWith(
      ConflictPolicy.customThreeWay((base, local, remote) => local),
    );

    await engine.set('tasks', 'a', {'title': 'local edit'});
    remote.seed(
      'tasks',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 13),
      version: 2,
    );
    await engine.sync();

    // Still dirty, so the application can act on it — and still visible as
    // the local edit, so nothing was silently taken away from the user.
    final meta = await engine.metadata.readRecord('tasks', 'a');
    expect(meta!.dirty, isTrue);
    expect((await engine.get('tasks', 'a'))!['title'], 'local edit');
  });

  test('once the app resolves it by writing again, the record pushes normally',
      () async {
    final engine = await engineWith(
      ConflictPolicy.customThreeWay((base, local, remote) => local),
    );

    await engine.set('tasks', 'a', {'title': 'local edit'});
    remote.seed(
      'tasks',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 13),
      version: 2,
    );
    await engine.sync();

    // The application decides — an explicit write is the decision.
    await engine.set('tasks', 'a', {'title': 'user decided'});
    await engine.flush();

    expect(remote.documents['tasks']!['a']!['title'], 'user decided');
    expect((await engine.metadata.readRecord('tasks', 'a'))!.dirty, isFalse);
  });
}
