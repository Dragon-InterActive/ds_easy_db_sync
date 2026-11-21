import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// An adapter whose cursor never moves while it keeps claiming more pages.
class _StuckAdapter implements SyncRemoteAdapter {
  int pulls = 0;

  @override
  SyncCapabilities get capabilities => const SyncCapabilities(
        supportsTimestamps: true,
        supportsDeltaPull: true,
        supportsDeltaDeletes: true,
      );

  @override
  SyncError mapError(Object error, StackTrace stackTrace) =>
      const SyncError(SyncErrorKind.transient);

  @override
  Future<DeltaResult> pullSince(String collection, Object? cursor) async {
    pulls++;
    if (pulls > 50) throw StateError('endless pull loop');
    return const DeltaResult(nextCursor: 'same', hasMore: true);
  }

  @override
  Future<List<PushResult>> pushBatch(List<PushItem> items) async =>
      const <PushResult>[];
}

void main() {
  test('a cursor that does not advance stops the pull instead of looping',
      () async {
    final warnings = <String>[];
    final remote = _StuckAdapter();
    final engine = SyncEngine()
      ..configure(
        local: MockDatabase(),
        remote: remote,
        config: SyncConfig(collections: const ['t'], onWarning: warnings.add),
      );
    await engine.init();

    await engine.sync();
    await engine.sync();

    // First pass: initial page plus the one that repeated the cursor.
    // Second pass starts at 'same' and stops after its first page.
    expect(remote.pulls, 3);
    expect(warnings.where((w) => w.contains('did not advance')), hasLength(2));
  });
}
