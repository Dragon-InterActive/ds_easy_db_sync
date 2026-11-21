# ds_easy_db_sync

An optional **offline-first sync engine** for the
[ds_easy_db](https://pub.dev/packages/ds_easy_db) ecosystem.

Writes go to a local cache and return at once. The engine remembers what changed,
pushes it when you sync, pulls remote changes back and resolves conflicts with the
policy **you** chose. It provides the mechanism; your app decides the policy: which
conflict strategy applies, when to sync, and whether to sync at all.

> **Pre-release (0.1.x).** The API may still change before 1.0.0.

## Features

- **Local first:** `set`, `update` and `delete` never wait for the network.
- **Delta sync:** pull first, then push, with a cursor per collection. Adapters
  without delta support fall back to full pulls automatically.
- **Configurable conflict resolution:** `lastWriteWins`, `serverWins`,
  `clientWins`, a custom two-way merge, or a three-way merge, globally or per
  collection.
- **Delete conflicts as a separate decision:** what happens when one side deletes
  and the other edits.
- **Soft deletes (tombstones):** deleted records disappear from reads at once;
  the remote delete follows on the next push.
- **Server timestamps that survive offline writes:** `DatabaseRepository.serverTS`
  is stamped by the backend on push and written back into the cache.
- **Retries with backoff** and hooks for `unauthorized`, quota and payment errors.
- **Several users per device:** optional per-user scoping and `purgeUser`.
- **Opt-in triggers:** manual, periodic or on connectivity changes. Nothing runs
  on its own.

## When to use it

Use the engine when your app has to work offline and keep a local copy in step
with a backend. If you only need a cache, or prefer to move data yourself, keep
using the `cache` and `storage` slots of `ds_easy_db` directly. The engine is an
add-on, not a requirement.

## Installation

```yaml
dependencies:
  ds_easy_db: ^1.1.1
  ds_easy_db_sync: ^0.1.0
  ds_easy_db_hive: ^1.1.0        # local cache
  ds_easy_db_firestore: ^1.1.0   # remote, with FirestoreSyncAdapter
```

Any `DatabaseRepository` works as the local side. The remote side needs an adapter
that implements `SyncRemoteAdapter` from
[ds_sync_contract](https://pub.dev/packages/ds_sync_contract). Ready-made adapters:

| Package | Adapter |
| --- | --- |
| `ds_easy_db_firestore` | `FirestoreSyncAdapter` |
| `ds_easy_db_firebase_realtime` | `RealtimeSyncAdapter` |

## Quickstart

```dart
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_firestore/ds_easy_db_firestore.dart';
import 'package:ds_easy_db_hive/ds_easy_db_hive.dart';
import 'package:ds_easy_db_sync/ds_easy_db_sync.dart';
import 'package:firebase_core/firebase_core.dart';

final sync = SyncEngine();

Future<void> main() async {
  await Firebase.initializeApp();

  sync.configure(
    local: HiveDatabase(),
    remote: FirestoreSyncAdapter(),
    config: const SyncConfig(collections: ['tasks']),
  );
  await sync.init();

  // Writes are local and return immediately.
  await sync.set('tasks', 't1', {
    'title': 'Buy milk',
    'createdAt': DatabaseRepository.serverTS,
  });

  // Reads come from the cache. Soft-deleted records are hidden.
  final task = await sync.get('tasks', 't1');

  // Pull, then push.
  final report = await sync.sync();
  print('pushed ${report.pushed}, pulled ${report.pulled}');
}
```

If the cache is already configured as `db.cache`, pass `local: db.cache!` instead.

## How a sync pass works

`sync()` runs over every configured collection, `syncCollection()` over one:

1. **Pull.** The adapter returns everything changed since the stored cursor.
   Records without local changes are written into the cache. Records that also
   changed locally are conflicts and go to the collection's policy. The cursor
   advances only once the pull has completed; after a failed page it stays put.
2. **Push.** Every dirty record, including pending deletes, goes out in batches of
   `pushBatchSize`. A record becomes clean only when the backend confirms it, so an
   interrupted push is simply repeated.
3. **Tombstone cleanup.** Confirmed deletes are removed after `tombstoneRetention`.

`flush()` only pushes. Use it, for example, before a logout. The real safety net is
that dirty flags are persisted: changes that were never pushed survive an app kill
and go out with the next pass.

Sync metadata lives in its own namespace (`__ds_sync__…`) in the local repository.
It never ends up in your documents or on the backend. Collection names starting with
`__ds_sync__` are therefore rejected.

## Configuration

Everything the engine decides on your behalf is in `SyncConfig`:

| Option | Default | Purpose |
| --- | --- | --- |
| `collections` | required | The collections to sync. Nothing else is touched. |
| `defaultPolicy` / `collectionPolicies` | `lastWriteWins` | Content conflicts |
| `defaultDeletePolicy` / `collectionDeletePolicies` | `DeleteConflictPolicy.serverWins` | Delete conflicts |
| `userScope` | `UserScope.single` | One user per installation or several |
| `missingConflictAnchor` | `strict` | Refuse to start if the adapter cannot detect conflicts |
| `missingDeltaPull` / `missingDeltaDeletes` | `degrade` | Fall back to full pulls, with a warning |
| `tombstoneRetention` | 30 days | How long confirmed deletes are remembered |
| `maxRetries` | 5 | Failed attempts before the engine gives up on a record |
| `initialBackoff` / `rateLimitBackoff` / `maxBackoff` | 5 s / 1 min / 30 min | Retry timing |
| `pushBatchSize` | 50 | Records per `pushBatch` call |
| `onWarning` | – | Degradations and skipped operations |
| `onSyncError`, `onUnauthorized`, `onQuotaExceeded`, `onPaymentRequired` | – | Error hooks |
| `onPurgeRemote` | – | Remote half of `purgeUser(…, scope: PurgeScope.localAndRemote)` |

## Conflict policies

A conflict means the record has local changes that were not pushed yet **and** the
backend has a newer version. If the remote copy has not changed since the last
sync, there is no conflict: the local change is pushed.

| Policy | Result | Fits |
| --- | --- | --- |
| `ConflictPolicy.lastWriteWins` | The newer change wins | Low-stakes data: shopping list, cleaning plan |
| `ConflictPolicy.serverWins` | The backend wins | Data the server owns |
| `ConflictPolicy.clientWins` | The device wins | Drafts owned by the device |
| `ConflictPolicy.custom(merge)` | `merge(local, remote)` | Data where both edits must survive |
| `ConflictPolicy.customThreeWay(merge)` | `merge(base, local, remote)` | Precise merges; stores one base copy per record |

Pick the policy per collection, not once for the whole app. `lastWriteWins` is
fine for a cleaning plan and loses money in a shared cash book:

```dart
SyncConfig(
  collections: const ['tasks', 'cash_book'],
  collectionPolicies: {
    'cash_book': ConflictPolicy.custom((local, remote) => {
          ...remote,
          'entries': {
            ...?(remote['entries'] as List?),
            ...?(local['entries'] as List?),
          }.toList(),
        }),
  },
);
```

`lastWriteWins` needs timestamps from the adapter, and `customThreeWay` needs a
stored base. When either is missing, the engine does not guess. It keeps the record
dirty, marks it as unresolved (`SyncReport.unresolved`) and holds it back from the
push until your app writes the record again.

### Delete conflicts

When one side deletes a record and the other edits it, `DeleteConflictPolicy`
decides. The same policy applies to both directions:

| Policy | Result |
| --- | --- |
| `serverWins` (default) | The backend's version of events wins |
| `clientWins` | The device's version of events wins |
| `deleteWins` | The record is deleted on both sides |
| `modifyWins` | The edit brings the record back |
| `lastWriteWins` | The later event wins, where both sides have a time |
| `DeleteConflictPolicy.custom(resolve)` | `resolve(context)` returns `DeleteConflictOutcome.delete` or `.keep(document)` |

A remote delete reported by a delta pull carries no timestamp. With `lastWriteWins`
the engine then keeps the edit and emits a warning.

## Server timestamps

Use `DatabaseRepository.serverTS` for synced timestamps, never `DateTime.now()`.
Offline, the cache stores the local time for the moment. On push, the field is sent
as a server timestamp, and the time the backend assigns is written back into the
cache. After that the field is done: later updates do not stamp it again.

## Users

With `UserScope.perDevice`, every key is prefixed with the active user, so one
user's data and pending changes stay invisible to the next.

```dart
sync.setActiveUser('alice');
// …
await sync.flush();
await sync.whenIdle();
sync.setActiveUser('bob'); // Alice's unpushed changes stay for her next session
```

`setActiveUser` and `clearActiveUser` throw a `SyncBusyException` while a sync
pass, flush or purge is running. `await sync.whenIdle()` first; `isSyncing` tells
you whether something is running.

`purgeUser(userId)` removes a user's local data and sync metadata. With
`scope: PurgeScope.localAndRemote` the engine also calls `onPurgeRemote`. What
deleting a user on the backend means (accounts, retention duties) is your app's
decision, so the engine deletes nothing remotely on its own.

## Triggers

Nothing syncs unless you say so:

```dart
await sync.sync();                                  // manually
sync.startPeriodicSync(const Duration(minutes: 15));
sync.attachConnectivityTrigger(onlineStream);        // Stream<bool>, true = online
await sync.dispose();                               // stops both triggers
```

Passes never overlap. A `sync()` started while another pass runs is skipped with a
warning. `flush()` and `purgeUser()` wait for the running pass instead.

## Errors

The adapter maps every backend error to a `SyncErrorKind`. A failed record goes to
the matching hook (`onUnauthorized`, `onQuotaExceeded`, `onPaymentRequired`), or to
`onSyncError` when there is no specific one. Without a hook, or when the hook
returns `null`, the record stays dirty and is retried with exponential backoff,
longer after a rate limit. A hook returns a `SyncResolution`:

```dart
SyncConfig(
  collections: const ['tasks'],
  onUnauthorized: (context) async {
    await refreshToken();
    return SyncResolution.retryNow;
  },
  onSyncError: (context) => null, // null = keep the record dirty, stay quiet
);
```

`retryNow` retries on the next pass, `dropRecord` discards the local record,
`leaveDirty` (or `null`) keeps it for later. After `maxRetries` failed attempts the
engine stops trying that record until your app writes it again.

Each pass returns a `SyncReport` with `pulled`, `pushed`, `conflicts`, `unresolved`,
`deletedLocally`, `deletedRemotely`, `tombstonesCollected`, `failed` and `errors`.

## Backend requirements

The engine is only as good as the adapter's change tracking:

- **Firestore** (`FirestoreSyncAdapter`): documents need an `updatedAt` field (the
  adapter stamps it on push) and a composite index on `updatedAt` + `__name__`.
  Firestore cannot report hard-deleted documents in a query. Without a
  `deletedField` (remote soft-delete flag) the engine therefore uses full pulls,
  which is correct but costs one read per document and pass.
- **Realtime Database** (`RealtimeSyncAdapter`): needs an `.indexOn` rule for
  `updatedAt`; the same applies to deletions.

To write an adapter for another backend, implement `SyncRemoteAdapter` from
[ds_sync_contract](https://pub.dev/packages/ds_sync_contract).

## Limitations

- Payload and metadata are two writes on the local backend, not one transaction.
- `query` filters in the engine, on the visible documents of the active user, and
  adds the document id as `id`. Keep synced collections reasonably small.
- Full pulls (adapters without delta support) grow with the collection size.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
