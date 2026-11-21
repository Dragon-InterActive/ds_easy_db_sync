/// Optional offline-first synchronization engine for the `ds_easy_db`
/// ecosystem.
///
/// The engine provides mechanism — dirty tracking, conflict resolution,
/// delta push/pull, soft-delete. The application chooses the policy: which
/// conflict strategy applies, when to sync, and whether to sync at all.
library;

export 'package:ds_sync_contract/ds_sync_contract.dart';

export 'src/engine/conflict_resolver.dart';
export 'src/engine/sync_config.dart';
export 'src/engine/sync_engine.dart';
export 'src/engine/sync_report.dart';
export 'src/meta/collection_meta.dart';
export 'src/meta/metadata_store.dart';
export 'src/meta/record_meta.dart';
export 'src/meta/sync_codec.dart';
export 'src/meta/sync_keys.dart';
export 'src/meta/sync_runtime_state.dart';
