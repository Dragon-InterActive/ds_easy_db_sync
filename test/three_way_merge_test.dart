// ConflictPolicy.customThreeWay — previously untested. Covers the extra
// storage cost (a base copy, kept only when the policy is active), the
// three arguments the merge function receives, that the merge result is
// pushed, and the documented fallback when no base exists yet.
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

  test(
      'a base copy is stored only for collections under a three-way policy, '
      'not for others — it is an opt-in storage cost', () async {
    final engine = SyncEngine()
      ..configure(
        local: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['threeway', 'plain'],
          collectionPolicies: {
            'threeway': ConflictPolicy.customThreeWay(
              (base, local, remote) => remote,
            ),
          },
        ),
      );
    await engine.init();

    remote.seed('threeway', 'a', {'title': 'x'});
    remote.seed('plain', 'a', {'title': 'x'});
    await engine.sync();

    expect((await engine.metadata.readRecord('threeway', 'a'))!.base,
        {'title': 'x'});
    expect((await engine.metadata.readRecord('plain', 'a'))!.base, isNull,
        reason: 'lastWriteWins never needs a base copy — storing one would '
            'be an unpaid-for cost');
  });

  test(
      'the merge function receives (base, local, remote) and the result is '
      'written back locally and pushed', () async {
    final seenArgs = <List<SyncDocument>>[];
    final engine = SyncEngine()
      ..configure(
        local: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['notes'],
          defaultPolicy: ConflictPolicy.customThreeWay((base, local, remote) {
            seenArgs.add([base, local, remote]);
            return {
              'title': '${local['title']}+${remote['title']}',
              'baseTitle': base['title'],
            };
          }),
        ),
      );
    await engine.init();

    // First sync establishes the common ancestor.
    remote.seed('notes', 'a', {'title': 'ancestor'});
    await engine.sync();
    expect((await engine.metadata.readRecord('notes', 'a'))!.base,
        {'title': 'ancestor'});

    // Both sides edit independently from that ancestor.
    await engine.set('notes', 'a', {'title': 'local edit'});
    remote.seed(
      'notes',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 13),
      version: 2,
    );

    final report = await engine.sync();
    expect(report.conflicts, 1);

    expect(seenArgs, hasLength(1));
    expect(seenArgs.single[0]['title'], 'ancestor'); // base
    expect(seenArgs.single[1]['title'], 'local edit'); // local
    expect(seenArgs.single[2]['title'], 'remote edit'); // remote

    final merged = await engine.get('notes', 'a');
    expect(merged!['title'], 'local edit+remote edit');
    expect(merged['baseTitle'], 'ancestor');

    // A merge result exists on neither side yet, so it had to be pushed.
    expect(remote.documents['notes']!['a']!['title'], 'local edit+remote edit');
    expect((await engine.metadata.readRecord('notes', 'a'))!.dirty, isFalse);
  });

  test(
      'without a stored base the local copy is kept, stays dirty, and a '
      'warning is emitted — the merge is never guessed at', () async {
    final merged = <String>[];
    final engine = SyncEngine()
      ..configure(
        local: cache,
        remote: remote,
        config: SyncConfig(
          clock: fixedNow,
          collections: const ['notes'],
          defaultPolicy: ConflictPolicy.customThreeWay((base, local, remote) {
            merged.add('called');
            return remote;
          }),
          onWarning: warnings.add,
        ),
      );
    await engine.init();

    // A record dirtied locally that has never been synced before — so no
    // base copy exists — while the remote already holds a conflicting copy.
    await engine.set('notes', 'a', {'title': 'local edit'});
    remote.seed(
      'notes',
      'a',
      {'title': 'remote edit'},
      updatedAt: DateTime.utc(2026, 6, 1, 13),
      version: 2,
    );

    final report = await engine.sync();
    expect(report.conflicts, 1);
    expect(report.unresolved, 1);

    expect(merged, isEmpty, reason: 'the merge fn must not run without a base');
    expect((await engine.get('notes', 'a'))!['title'], 'local edit');

    final meta = (await engine.metadata.readRecord('notes', 'a'))!;
    expect(meta.dirty, isTrue);
    expect(
      meta.conflicted,
      isTrue,
      reason: 'an undecided conflict must be held back from the push, or the '
          'local copy silently overwrites the remote edit',
    );
    expect(
      warnings.join(),
      contains('three-way merge needs a stored base copy'),
    );
  });
}
