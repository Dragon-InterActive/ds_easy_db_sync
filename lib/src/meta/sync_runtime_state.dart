/// Sync state that deliberately lives in memory only.
///
/// Backoff timing and in-flight markers must **not** be persisted: after an
/// app restart there is nothing in flight, and a stale `nextRetryAt` would
/// keep the engine silent for no reason. What *is* persisted is the retry
/// counter (`RecordMeta.retryCount`), so giving up survives a restart while
/// the waiting does not.
class SyncRuntimeState {
  final Map<String, DateTime> _nextRetryAt = <String, DateTime>{};
  final Set<String> _inFlight = <String>{};
  final Map<String, int> _writeSequence = <String, int>{};

  /// Whether [key] is currently being pushed.
  ///
  /// Guards against a second sync pass picking up a record that a running pass
  /// already sent.
  bool isInFlight(String key) => _inFlight.contains(key);

  /// Marks [key] as being pushed right now.
  void markInFlight(String key) => _inFlight.add(key);

  /// Clears the in-flight marker for [key], whatever the outcome was.
  void clearInFlight(String key) => _inFlight.remove(key);

  /// Counts a local write to [key].
  ///
  /// A push compares the counter before and after its round trip: a change
  /// means the application wrote the record while it was on the wire, so the
  /// confirmed push must not clear the dirty flag of that newer write.
  void noteLocalWrite(String key) =>
      _writeSequence[key] = writeSequence(key) + 1;

  /// The number of local writes to [key] seen so far.
  int writeSequence(String key) => _writeSequence[key] ?? 0;

  /// Records that [key] must not be retried before [time].
  void setNextRetry(String key, DateTime time) => _nextRetryAt[key] = time;

  /// Drops any backoff for [key] — used after a successful push or an explicit
  /// `SyncResolution.retryNow`.
  void clearNextRetry(String key) => _nextRetryAt.remove(key);

  /// Whether [key] may be attempted at [now].
  ///
  /// Records with no backoff are always eligible.
  bool isEligible(String key, DateTime now) {
    if (_inFlight.contains(key)) return false;
    final next = _nextRetryAt[key];
    return next == null || !now.isBefore(next);
  }

  /// Forgets all runtime state — used on user switch and on shutdown.
  void clear() {
    _nextRetryAt.clear();
    _inFlight.clear();
    _writeSequence.clear();
  }
}
