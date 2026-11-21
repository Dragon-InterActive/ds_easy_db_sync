import 'package:ds_sync_contract/ds_sync_contract.dart';

/// What one sync pass actually did.
///
/// Returned rather than logged, so the application can decide what to show —
/// a silent background pass and a user-triggered "Sync now" want very
/// different feedback.
class SyncReport {
  /// Creates a report for one pass.
  const SyncReport({
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.unresolved = 0,
    this.deletedLocally = 0,
    this.deletedRemotely = 0,
    this.tombstonesCollected = 0,
    this.failed = 0,
    this.cursorAdvanced = false,
    this.errors = const <SyncError>[],
  });

  /// Records applied from the remote side.
  final int pulled;

  /// Records confirmed written to the remote side.
  final int pushed;

  /// Conflicts that were resolved through a policy.
  final int conflicts;

  /// Conflicts the configured policy could not decide.
  ///
  /// These records are kept locally, stay dirty and are **held back from the
  /// push** until the application writes them again — the engine will not
  /// break the tie on its own. A non-zero value here means the app has
  /// something to resolve.
  final int unresolved;

  /// Records removed locally because the remote deleted them.
  final int deletedLocally;

  /// Tombstones whose remote delete the backend confirmed.
  final int deletedRemotely;

  /// Tombstones garbage collected after their retention elapsed.
  final int tombstonesCollected;

  /// Records that could not be synced in this pass.
  final int failed;

  /// Whether the delta cursor advanced — false after a partial pull.
  final bool cursorAdvanced;

  /// The errors encountered, already normalised.
  final List<SyncError> errors;

  /// Whether the pass completed without a single failure.
  bool get isClean => failed == 0 && unresolved == 0 && errors.isEmpty;

  /// Merges two reports, for a pass spanning several collections.
  SyncReport merge(SyncReport other) {
    return SyncReport(
      pulled: pulled + other.pulled,
      pushed: pushed + other.pushed,
      conflicts: conflicts + other.conflicts,
      unresolved: unresolved + other.unresolved,
      deletedLocally: deletedLocally + other.deletedLocally,
      deletedRemotely: deletedRemotely + other.deletedRemotely,
      tombstonesCollected: tombstonesCollected + other.tombstonesCollected,
      failed: failed + other.failed,
      cursorAdvanced: cursorAdvanced && other.cursorAdvanced,
      errors: <SyncError>[...errors, ...other.errors],
    );
  }

  @override
  String toString() => 'SyncReport(pulled: $pulled, pushed: $pushed, '
      'conflicts: $conflicts, unresolved: $unresolved, '
      'deletedLocally: $deletedLocally, '
      'deletedRemotely: $deletedRemotely, '
      'tombstonesCollected: $tombstonesCollected, failed: $failed, '
      'cursorAdvanced: $cursorAdvanced)';
}

/// Mutable accumulator used while a pass runs.
class SyncReportBuilder {
  /// Records applied from the remote side.
  int pulled = 0;

  /// Records confirmed written to the remote side.
  int pushed = 0;

  /// Conflicts resolved through a policy.
  int conflicts = 0;

  /// Conflicts no policy could decide.
  int unresolved = 0;

  /// Records removed locally because the remote deleted them.
  int deletedLocally = 0;

  /// Tombstones whose remote delete was confirmed.
  int deletedRemotely = 0;

  /// Tombstones garbage collected.
  int tombstonesCollected = 0;

  /// Records that could not be synced.
  int failed = 0;

  /// Whether the cursor was advanced in this pass.
  bool cursorAdvanced = false;

  /// Errors collected so far.
  final List<SyncError> errors = <SyncError>[];

  /// Freezes the accumulated counters into a [SyncReport].
  SyncReport build() => SyncReport(
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        unresolved: unresolved,
        deletedLocally: deletedLocally,
        deletedRemotely: deletedRemotely,
        tombstonesCollected: tombstonesCollected,
        failed: failed,
        cursorAdvanced: cursorAdvanced,
        errors: List<SyncError>.unmodifiable(errors),
      );
}
