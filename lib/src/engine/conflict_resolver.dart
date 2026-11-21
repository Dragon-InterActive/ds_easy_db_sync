import 'package:ds_sync_contract/ds_sync_contract.dart';

/// The result of resolving a content conflict.
class ConflictOutcome {
  /// Creates a resolution outcome.
  const ConflictOutcome({
    required this.document,
    required this.stillDirty,
    required this.resolved,
    this.warning,
  });

  /// The document that wins and is written to the local cache.
  final SyncDocument document;

  /// Whether the winning document still has to be pushed.
  ///
  /// True whenever the result differs from what the remote holds — i.e. for
  /// `clientWins` and for every custom merge, because a merged document exists
  /// on neither side yet.
  final bool stillDirty;

  /// Whether a policy could actually decide.
  ///
  /// False means the conflict was left alone rather than guessed at; nothing
  /// is lost, and the remote copy will be offered again on the next pull.
  final bool resolved;

  /// Why the conflict could not be resolved, when [resolved] is false.
  final String? warning;
}

/// Applies conflict policies. Pure decision logic — no storage, no network.
///
/// Every method here answers "who wins", never "who should win by default":
/// the strategy always comes from the application's configuration.
abstract final class ConflictResolver {
  /// Resolves a content conflict between [local] and [remote] under [policy].
  ///
  /// [localUpdatedAt] and [remoteUpdatedAt] are only consulted by
  /// `lastWriteWins`. If that policy is active but no remote timestamp exists,
  /// nothing is decided: the local copy stays dirty and untouched, so no edit
  /// is discarded on a guess.
  static ConflictOutcome resolveContent({
    required ConflictPolicy policy,
    required SyncDocument local,
    required SyncDocument remote,
    required DateTime localUpdatedAt,
    DateTime? remoteUpdatedAt,
    SyncDocument? base,
  }) {
    switch (policy) {
      case ServerWinsPolicy():
        return ConflictOutcome(
          document: remote,
          stillDirty: false,
          resolved: true,
        );

      case ClientWinsPolicy():
        return ConflictOutcome(
          document: local,
          stillDirty: true,
          resolved: true,
        );

      case LastWriteWinsPolicy():
        if (remoteUpdatedAt == null) {
          return ConflictOutcome(
            document: local,
            stillDirty: true,
            resolved: false,
            warning: 'lastWriteWins needs a remote timestamp, but the adapter '
                'provided none. The local copy was kept and stays dirty; '
                'no edit was discarded.',
          );
        }
        final remoteWins = remoteUpdatedAt.isAfter(localUpdatedAt);
        return ConflictOutcome(
          document: remoteWins ? remote : local,
          stillDirty: !remoteWins,
          resolved: true,
        );

      case CustomMergePolicy(:final merge):
        return ConflictOutcome(
          document: merge(local, remote),
          stillDirty: true,
          resolved: true,
        );

      case CustomThreeWayMergePolicy(:final merge):
        if (base == null) {
          return ConflictOutcome(
            document: local,
            stillDirty: true,
            resolved: false,
            warning: 'A three-way merge needs a stored base copy, but none '
                'exists for this record yet. The local copy was kept and '
                'stays dirty.',
          );
        }
        return ConflictOutcome(
          document: merge(base, local, remote),
          stillDirty: true,
          resolved: true,
        );
    }
  }

  /// Resolves a delete-vs-update conflict under [policy].
  ///
  /// [deletedAt] and [modifiedAt] are only consulted by `lastWriteWins`. When
  /// either is missing the modification is kept — the choice that destroys
  /// nothing — and a warning is attached, because a policy that cannot compare
  /// is a policy that silently is not the one the application configured.
  static DeleteResolution resolveDelete({
    required DeleteConflictPolicy policy,
    required DeleteConflictContext context,
    DateTime? deletedAt,
    DateTime? modifiedAt,
  }) {
    final remoteDeleted =
        context.direction == DeleteConflictDirection.localModifyRemoteDelete;

    switch (policy) {
      case DeleteWinsPolicy():
        return const DeleteResolution(DeleteConflictOutcome.delete);

      case ModifyWinsPolicy():
        return DeleteResolution(
          DeleteConflictOutcome.keep(context.survivingDocument),
        );

      case DeleteServerWinsPolicy():
        return DeleteResolution(
          remoteDeleted
              ? DeleteConflictOutcome.delete
              : DeleteConflictOutcome.keep(context.survivingDocument),
        );

      case DeleteClientWinsPolicy():
        return DeleteResolution(
          remoteDeleted
              ? DeleteConflictOutcome.keep(context.survivingDocument)
              : DeleteConflictOutcome.delete,
        );

      case DeleteLastWriteWinsPolicy():
        if (deletedAt == null || modifiedAt == null) {
          return DeleteResolution(
            DeleteConflictOutcome.keep(context.survivingDocument),
            warning: 'lastWriteWins cannot order the delete against the '
                'modification for "${context.collection}/${context.docId}": '
                '${deletedAt == null ? 'the delete' : 'the modification'} '
                'carries no timestamp. The modification was kept, so nothing '
                'was destroyed — but this is not the ordering the policy '
                'promises. A remote delete only carries a time if the adapter '
                'reports deletions with one.',
          );
        }
        return DeleteResolution(
          deletedAt.isAfter(modifiedAt)
              ? DeleteConflictOutcome.delete
              : DeleteConflictOutcome.keep(context.survivingDocument),
        );

      case CustomDeleteConflictPolicy(:final resolve):
        return DeleteResolution(resolve(context));
    }
  }
}

/// A delete-conflict decision, plus anything the application should know about
/// how it was reached.
class DeleteResolution {
  /// Wraps [outcome], optionally with a [warning].
  const DeleteResolution(this.outcome, {this.warning});

  /// What happens to the record.
  final DeleteConflictOutcome outcome;

  /// Set when the configured policy could not be applied as promised.
  final String? warning;
}
