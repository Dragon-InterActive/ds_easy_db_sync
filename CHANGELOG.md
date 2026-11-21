## 0.1.0

* Initial release of the offline-first sync engine for the `ds_easy_db`
  ecosystem, built on `ds_sync_contract` 0.1.0.
* `SyncEngine` with `configure` / `init`: capability checks per
  `CapabilityFallback`; adapters without delta pull or delta deletes fall back
  to full pulls with simulated delta.
* Write path: `set`, `update`, `delete` hit the local cache and return at once;
  records are marked dirty in the reserved `__ds_sync__` metadata namespace.
  `delete` is a soft delete (tombstone).
* Read path: `get`, `getAll`, `query`, `exists` hide tombstoned records;
  `query` adds the document id as `id`, like every `ds_easy_db` backend.
* Sync: `sync`, `syncCollection` (pull first, then push) and `flush`
  (push only); per-collection cursor, advanced only after a complete pull.
* Conflict resolution per collection through `ConflictPolicy` and
  `DeleteConflictPolicy`; undecidable conflicts are held back instead of being
  pushed.
* Per-record push results, retries with exponential backoff, `maxRetries`, and
  the `onUnauthorized`, `onQuotaExceeded`, `onPaymentRequired` and
  `onSyncError` handlers.
* `serverTS` fields are re-sent on push, stamped by the backend once and
  written back into the cache.
* Tombstone garbage collection after `tombstoneRetention`, counted from the
  confirmed remote delete.
* Users: `UserScope.single` and `UserScope.perDevice`, `setActiveUser`,
  `clearActiveUser`, `purgeUser` (optionally `localAndRemote` through
  `onPurgeRemote`).
* Opt-in triggers: `attachConnectivityTrigger`, `startPeriodicSync`.

### Guarantees worth knowing

* A remote copy that has not changed since the last sync is never a conflict:
  a local edit or delete is pushed, not reverted by the policy.
* A write made while its record is being pushed is not lost; it stays dirty
  and goes out with the next push.
* `update` on a soft-deleted record starts a new document from the given
  fields; the tombstone's old payload does not come back.
* `sync`, `syncCollection`, `flush` and `purgeUser` never overlap. `sync` is
  skipped with a warning while another pass runs; `flush` and `purgeUser` wait
  for it.
* `setActiveUser` and `clearActiveUser` throw `SyncBusyException` while a pass
  runs. Use `isSyncing` to check and `await whenIdle()` before switching.
* `purgeUser` in `UserScope.single` removes payload, record metadata and the
  cursor, so the next pull restores the server state.
* A pull whose cursor does not advance although the adapter reports more pages
  stops with a warning instead of looping.
* Stored times keep microsecond precision; millisecond values from
  pre-release builds are still read.
