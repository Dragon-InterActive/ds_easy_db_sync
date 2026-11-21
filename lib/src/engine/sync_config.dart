import 'dart:async';

import 'package:ds_sync_contract/ds_sync_contract.dart';

/// Context handed to an error handler when a record could not be synced.
class SyncErrorContext {
  /// Creates the context for a failed sync operation.
  const SyncErrorContext({
    required this.collection,
    required this.error,
    this.docId,
    this.retryCount = 0,
  });

  /// The collection the failure happened in.
  final String collection;

  /// The record that failed, if the failure was record-specific.
  final String? docId;

  /// The normalised backend error.
  final SyncError error;

  /// How often this record has failed in a row so far.
  final int retryCount;

  @override
  String toString() => 'SyncErrorContext($collection'
      '${docId == null ? '' : '/$docId'}, ${error.kind.name}, '
      'retries: $retryCount)';
}

/// Handles a sync failure and decides what happens to the record.
///
/// Returning `null` selects the safe default: the record stays dirty and the
/// engine goes quiet. Handlers may be asynchronous — refreshing a token before
/// answering `SyncResolution.retryNow` is the point of the hook.
typedef SyncErrorHandler = FutureOr<SyncResolution?> Function(
  SyncErrorContext context,
);

/// Reports a non-fatal condition — a degraded capability, a skipped record.
typedef SyncWarningHandler = void Function(String message);

/// Supplies "now" for local timestamps and backoff scheduling.
///
/// Injectable so tests can pin local time to the same base the fake backend
/// stamps with — comparing a device clock against a server clock is exactly
/// what `lastWriteWins` does, and it has to be reproducible.
typedef SyncClock = DateTime Function();

/// Invoked when [PurgeScope.localAndRemote] is requested.
///
/// The engine deletes the local copy itself but never touches the backend's
/// auth or account data: what "delete this user remotely" means is an
/// application and data-protection decision, so it is delegated here.
typedef PurgeRemoteHandler = Future<void> Function(String userId);

/// How far a [purgeUser] call reaches.
enum PurgeScope {
  /// Delete the user's local payload and metadata only.
  local,

  /// Delete locally and additionally invoke the application's
  /// [PurgeRemoteHandler].
  localAndRemote,
}

/// Everything the engine needs to run — and every decision it refuses to make
/// on the application's behalf.
class SyncConfig {
  /// Creates a sync configuration.
  ///
  /// [collections] is explicit on purpose: the engine syncs what the
  /// application nominates, never everything it happens to find in the cache.
  const SyncConfig({
    required this.collections,
    this.userScope = UserScope.single,
    this.defaultPolicy = ConflictPolicy.lastWriteWins,
    this.collectionPolicies = const <String, ConflictPolicy>{},
    this.defaultDeletePolicy = DeleteConflictPolicy.serverWins,
    this.collectionDeletePolicies = const <String, DeleteConflictPolicy>{},
    this.missingConflictAnchor = CapabilityFallback.strict,
    this.missingDeltaPull = CapabilityFallback.degrade,
    this.missingDeltaDeletes = CapabilityFallback.degrade,
    this.tombstoneRetention = const Duration(days: 30),
    this.maxRetries = 5,
    this.initialBackoff = const Duration(seconds: 5),
    this.rateLimitBackoff = const Duration(minutes: 1),
    this.maxBackoff = const Duration(minutes: 30),
    this.pushBatchSize = 50,
    this.clock = _systemClock,
    this.onUnauthorized,
    this.onQuotaExceeded,
    this.onPaymentRequired,
    this.onSyncError,
    this.onWarning,
    this.onPurgeRemote,
  });

  /// The collections this engine synchronises.
  final List<String> collections;

  /// How local keys are scoped to users.
  final UserScope userScope;

  /// The content-conflict policy used where no override applies.
  final ConflictPolicy defaultPolicy;

  /// Per-collection content-conflict overrides.
  ///
  /// This is where a shared cash book gets `ConflictPolicy.custom` while the
  /// rest of the app stays on the default.
  final Map<String, ConflictPolicy> collectionPolicies;

  /// The delete-vs-update policy used where no override applies.
  final DeleteConflictPolicy defaultDeletePolicy;

  /// Per-collection delete-conflict overrides.
  final Map<String, DeleteConflictPolicy> collectionDeletePolicies;

  /// What to do when the adapter offers no conflict anchor at all.
  ///
  /// Defaults to [CapabilityFallback.strict]: without an anchor, conflicts are
  /// undetectable and edits would be lost silently. That is a data-loss risk,
  /// so the engine refuses to start rather than pretend.
  final CapabilityFallback missingConflictAnchor;

  /// What to do when the adapter cannot pull deltas.
  ///
  /// Defaults to [CapabilityFallback.degrade]: a full pull with simulated
  /// delta is correct, only expensive. Costs grow with collection size.
  final CapabilityFallback missingDeltaPull;

  /// What to do when a delta pull cannot report remote deletions.
  ///
  /// Defaults to [CapabilityFallback.degrade]: the engine falls back to full
  /// pulls, because a delta pull alone would leave remotely deleted records
  /// alive locally forever.
  final CapabilityFallback missingDeltaDeletes;

  /// How long a confirmed tombstone is kept before it is garbage collected.
  ///
  /// It must outlive the longest plausible offline period of any other device,
  /// or that device's stale copy would resurrect the record.
  final Duration tombstoneRetention;

  /// How often a record may fail in a row before the engine gives up on it and
  /// surfaces it to the handlers.
  final int maxRetries;

  /// Backoff after the first transient failure. Doubles per retry.
  final Duration initialBackoff;

  /// Backoff after a rate-limit response — deliberately longer.
  final Duration rateLimitBackoff;

  /// Upper bound for the exponential backoff.
  final Duration maxBackoff;

  /// How many records are handed to `pushBatch` at once.
  final int pushBatchSize;

  /// Supplies local "now". Defaults to the system clock in UTC.
  final SyncClock clock;

  /// Called on [SyncErrorKind.unauthorized]. Takes precedence over
  /// [onSyncError].
  final SyncErrorHandler? onUnauthorized;

  /// Called on [SyncErrorKind.quotaExceeded]. Takes precedence over
  /// [onSyncError].
  final SyncErrorHandler? onQuotaExceeded;

  /// Called on [SyncErrorKind.paymentRequired]. Takes precedence over
  /// [onSyncError].
  final SyncErrorHandler? onPaymentRequired;

  /// Catch-all for every error kind without a dedicated handler.
  final SyncErrorHandler? onSyncError;

  /// Receives degradation and skip warnings.
  final SyncWarningHandler? onWarning;

  /// Performs the remote half of [PurgeScope.localAndRemote].
  final PurgeRemoteHandler? onPurgeRemote;

  /// The content-conflict policy that applies to [collection].
  ConflictPolicy policyFor(String collection) =>
      collectionPolicies[collection] ?? defaultPolicy;

  /// The delete-conflict policy that applies to [collection].
  DeleteConflictPolicy deletePolicyFor(String collection) =>
      collectionDeletePolicies[collection] ?? defaultDeletePolicy;
}

DateTime _systemClock() => DateTime.now().toUtc();

/// Thrown at `init()` when the adapter cannot support the configured setup and
/// the matching [CapabilityFallback] is [CapabilityFallback.strict].
class SyncCapabilityException implements Exception {
  /// Creates a capability failure with an explanatory [message].
  const SyncCapabilityException(this.message);

  /// What is missing, and why running anyway would lose data.
  final String message;

  @override
  String toString() => 'SyncCapabilityException: $message';
}

/// Thrown when the engine is used before `configure()` and `init()`.
class SyncNotInitializedException implements Exception {
  /// Creates the not-initialised failure.
  const SyncNotInitializedException(this.message);

  /// What was attempted too early.
  final String message;

  @override
  String toString() => 'SyncNotInitializedException: $message';
}

/// Thrown when the active user is changed while a sync pass, flush or purge
/// is running.
///
/// Switching users under a running pass would let it write the previous
/// user's metadata into the new user's scope. Await
/// `SyncEngine.whenIdle()` first, then switch.
class SyncBusyException implements Exception {
  /// Creates the busy failure with an explanatory [message].
  const SyncBusyException(this.message);

  /// What was attempted while the engine was busy.
  final String message;

  @override
  String toString() => 'SyncBusyException: $message';
}
