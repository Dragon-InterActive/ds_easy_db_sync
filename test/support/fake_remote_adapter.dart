import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';

/// An in-memory remote backend, scriptable enough to reach the sharp edges.
///
/// It stamps its own authoritative timestamps, so `serverTS` write-back can be
/// observed, and it can be told to fail, rate-limit or report conflicts.
class FakeRemoteAdapter implements SyncRemoteAdapter {
  FakeRemoteAdapter({
    SyncCapabilities? capabilities,
    this.serverTime = fixedNow,
  }) : _capabilities = capabilities ??
            const SyncCapabilities(
              supportsTimestamps: true,
              supportsVersioning: true,
              supportsDeltaPull: true,
              supportsDeltaDeletes: true,
              supportsBatchWrite: true,
            );

  final SyncCapabilities _capabilities;

  /// Supplies the authoritative "server" time.
  final SyncClock serverTime;

  /// collection -> id -> document.
  final Map<String, Map<String, Map<String, dynamic>>> documents = {};

  /// collection -> id -> anchor.
  final Map<String, Map<String, RemoteAnchor>> anchors = {};

  /// Ids the backend reports as deleted on the next delta pull.
  final Map<String, List<String>> pendingDeletes = {};

  /// Pages the next pull will hand out instead of the stored state.
  List<DeltaResult>? scriptedPages;

  /// Thrown by the next [pullSince] call, once.
  Object? pullError;

  /// Forced outcome for every record of the next [pushBatch] call, once.
  PushStatus? forcedPushStatus;

  /// Ids whose push fails while the rest of the batch succeeds — the
  /// per-record outcome that makes a partial push retryable.
  final Set<String> failIds = <String>{};

  /// Error attached to a forced failure.
  SyncError? forcedPushError;

  /// Every batch the engine handed over, in order.
  final List<List<PushItem>> pushedBatches = [];

  int pullCount = 0;

  @override
  SyncCapabilities get capabilities => _capabilities;

  @override
  SyncError mapError(Object error, StackTrace stackTrace) {
    if (error is SyncError) return error;
    return SyncError(
      SyncErrorKind.transient,
      message: 'unreachable',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  /// Seeds a document as if it had always been on the server.
  void seed(
    String collection,
    String id,
    Map<String, dynamic> data, {
    DateTime? updatedAt,
    int version = 1,
  }) {
    documents.putIfAbsent(collection, () => {})[id] = data;
    anchors.putIfAbsent(collection, () => {})[id] = RemoteAnchor(
      version: version,
      updatedAt: updatedAt ?? serverTime(),
    );
  }

  /// Marks a document as deleted on the server side.
  void remoteDelete(String collection, String id) {
    documents[collection]?.remove(id);
    anchors[collection]?.remove(id);
    pendingDeletes.putIfAbsent(collection, () => []).add(id);
  }

  @override
  Future<DeltaResult> pullSince(String collection, Object? cursor) async {
    pullCount++;
    final error = pullError;
    if (error != null) {
      pullError = null;
      throw error;
    }

    final scripted = scriptedPages;
    if (scripted != null && scripted.isNotEmpty) {
      return scripted.removeAt(0);
    }

    final docs = documents[collection] ?? const {};
    final since = cursor is DateTime ? cursor : null;

    final changed = <RemoteRecord>[
      for (final entry in docs.entries)
        if (since == null ||
            (anchors[collection]?[entry.key]?.updatedAt ?? serverTime())
                .isAfter(since))
          RemoteRecord(
            id: entry.key,
            data: Map<String, dynamic>.from(entry.value),
            anchor: anchors[collection]?[entry.key] ?? const RemoteAnchor(),
          ),
    ];

    final deleted = List<String>.from(pendingDeletes[collection] ?? const []);
    pendingDeletes[collection]?.clear();

    return DeltaResult(
      changed: changed,
      deleted: deleted,
      nextCursor: serverTime(),
    );
  }

  @override
  Future<List<PushResult>> pushBatch(List<PushItem> items) async {
    pushedBatches.add(List<PushItem>.from(items));

    final forced = forcedPushStatus;
    if (forced != null) {
      forcedPushStatus = null;
      return [
        for (final item in items)
          PushResult(id: item.id, status: forced, error: forcedPushError),
      ];
    }

    final results = <PushResult>[];
    for (final item in items) {
      if (failIds.contains(item.id)) {
        results.add(PushResult(
          id: item.id,
          status: PushStatus.failed,
          error: const SyncError(SyncErrorKind.transient),
        ));
        continue;
      }
      if (item.isDelete) {
        documents[item.collection]?.remove(item.id);
        anchors[item.collection]?.remove(item.id);
        results.add(PushResult(id: item.id, status: PushStatus.success));
        continue;
      }

      // The backend resolves serverTS itself — that is the whole point of
      // re-sending it instead of the device's local time.
      final stamped = <String, dynamic>{
        for (final entry in item.data!.entries)
          entry.key: entry.value == DatabaseRepository.serverTS
              ? serverTime()
              : entry.value,
      };

      final previous = anchors[item.collection]?[item.id]?.version ?? 0;
      final anchor = RemoteAnchor(
        version: previous + 1,
        updatedAt: serverTime(),
      );
      documents.putIfAbsent(item.collection, () => {})[item.id] = stamped;
      anchors.putIfAbsent(item.collection, () => {})[item.id] = anchor;

      results.add(PushResult(
        id: item.id,
        status: PushStatus.success,
        newAnchor: anchor,
      ));
    }
    return results;
  }
}

/// The instant both the fake backend and the engine's clock are pinned to, so
/// "local time" and "server time" are comparable in tests.
DateTime fixedNow() => DateTime.utc(2026, 6, 1, 12);

/// A clock a test can move forward.
class MovableClock {
  MovableClock(this._now);

  DateTime _now;

  /// Reads the current instant. Pass this as a [SyncClock].
  DateTime now() => _now;

  /// Moves the clock forward by [by].
  void advance(Duration by) => _now = _now.add(by);
}
