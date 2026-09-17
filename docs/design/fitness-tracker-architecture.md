# Cross-Platform Fitness & Habit Tracker — Architecture and Technical Plan

**Status:** Draft for review
**Scope:** Flutter (Android first, iOS second), Fitbit ingestion, media capture, habit/streak engine
**Audience:** Solo developer / single-user deployment initially

---

## 0. Executive summary and the three findings that change the plan

Before the detailed analysis, three things surfaced that materially affect the design you sketched. They are worth reading first because two of them invalidate assumptions in the brief.

**Finding 1 — Fitbit does not write to Apple HealthKit, and has no plans to.** The pipeline `Fitbit → Apple HealthKit → app` does not exist. Fitbit's Android app writes to Health Connect, but on iOS the only routes are the Fitbit Web API (OAuth) or a third-party bridge app that the user installs and pays for. This means the iOS parity you're planning for is not a port of the same integration — it is a **second, structurally different ingestion pipeline**. Plan for it now (Section 3), or accept that iOS ships without Fitbit data.

**Finding 2 — "Zero changes to core business and presentation logic" is achievable, but not via the Repository pattern.** The Repository pattern alone does not deliver this; a naive repository abstraction leaks network semantics into the domain the moment you add a backend. What actually delivers it is a stricter rule: **the local database is permanently the read model, and the network is only a background replicator that writes into it.** The UI never awaits the network, ever. Adopt that rule and Strategy A → Strategy B stops being a migration and becomes an additive module. Section 1.4 enumerates precisely what leaks if you don't.

**Finding 3 — Isar should not be your local database.** Isar was abandoned by its original author; v4 never reached production readiness and the repository still carries a warning against using it. Community forks exist but are single-maintainer. Use **Drift** (SQLite-backed, actively maintained, reactive, isolate-aware). This is not just a maintenance argument: Drift's schema is SQL, which means your local DDL is ~90% identical to the eventual PostgreSQL DDL, and your local migrations are already written in the language you'll migrate to.

**Verdict:** Strategy A, in a hardened form ("A+") — local-first with sync-ready schema primitives from commit one. Detailed rationale in Section 1.5.

---

## 1. Architectural Strategy and Trade-Off Analysis

### 1.1 Framing the actual decision

The brief frames this as local-first *versus* backend-from-day-one. That framing is slightly off for this problem domain, for a reason specific to health apps:

Health Connect and HealthKit are **on-device data stores with no cloud API**. There is no server-side path to a user's Health Connect data. Whatever backend you build, the health ingestion pipeline is anchored on the device, reads on the device, and writes to device storage before anything else happens. Media capture is likewise device-anchored. A gym is frequently a signal dead zone.

So the app is device-first whether you like it or not. The real question is narrower: **when do you add a replication tier, and what does the schema look like before you do?**

### 1.2 Comparison matrix

| Dimension | Strategy A — Local-first MVP | Strategy B — Cloud from day 1 |
|---|---|---|
| **Setup overhead (solo dev)** | Hours. Add Drift, define tables, run codegen, ship. No auth, no accounts, no environments, no secrets management, no deployment. | Days to weeks. Auth flows, RLS policies or API scaffolding, environment separation, secret handling, CI for the backend, plus a deployment target to babysit. For Supabase, less; for a custom Go/FastAPI + Postgres + S3 stack, considerably more. |
| **Time to first useful feature** | Same day. You can log a workout on day one. | Sprint two at the earliest. Auth is a prerequisite for almost everything and delivers zero user-visible value for a single-user app. |
| **Offline resilience** | Native. Offline is not a mode, it is the only mode. No queue, no retry, no conflict resolution, no "you are offline" UI states. | Requires an offline layer anyway (see above — gyms have no signal), which means you build *both* the local store and the sync layer simultaneously. This is the worst of both worlds, and it is the single most common way solo projects stall. |
| **Sync complexity** | Deferred entirely. You pay zero sync tax until you actually need multi-device. | Paid up front, before you know your access patterns or which entities actually need to sync. You will design conflict resolution for a schema you're still changing weekly. |
| **Media handling** | Files land in the app documents directory. Compression is the only concern. No upload latency, no egress billing, no lifecycle policies, no presigned URL plumbing. Constraint: device storage is finite and media is unbacked-up. | Every video is an upload. You need chunked/resumable uploads, background upload scheduling, retry with backoff, progress UI, and a storage lifecycle policy. You also need thumbnails generated locally anyway for offline browsing — so you build the local pipeline regardless. Benefit: media survives device loss. |
| **Media cost (realistic, single user)** | ₹0. | At 60s of 720p H.264 per session (~18 MB) and 5 sessions/week: ~4.7 GB/year. Storage cost is trivial on R2/Supabase; the cost is *engineering*, not rupees. |
| **Schema iteration speed** | Very fast. One migration file, one place to change. Codegen catches breakage at compile time. | Slower. Local schema, remote schema, DTO mapping layer, and RLS policies all move together. Every entity change is a four-file change. |
| **Data durability** | Weak by default. Device loss = total loss. **Mitigate in Phase 1** with a manual export/import (SQLite file + media directory → zip → share sheet / Google Drive). This is a two-day task and removes 90% of the anxiety that pushes people toward Strategy B. |
| **Multi-device / device replacement** | Not supported until Phase 4. For a single user with one phone, this is a non-issue until it isn't. | Supported from day one. |
| **iOS expansion** | Neutral. Local storage is identical on both platforms. | Neutral, but the auth and account model must handle the platform migration case. |
| **Failure modes you own** | Corrupt local DB, storage exhaustion. Both bounded and debuggable on-device. | All of the above, plus: token expiry, partial upload states, sync loops, clock skew, RLS misconfiguration, and silent data divergence. Debugging these without observability is grim. |
| **Debuggability** | `adb pull` the SQLite file, open in any client. Ten seconds. | Distributed state across two stores. Reproducing a bug requires knowing both sides' state at a point in time. |

### 1.3 Migration friction from A to B — the honest accounting

This is the crux of the decision, so it deserves precision rather than reassurance.

**What costs nothing if you plan for it (Section 1.6 primitives):**

- Identifier allocation. If IDs are client-generated UUIDv7 from day one, no ID remapping is ever needed. If they are SQLite `AUTOINCREMENT` integers, you face a full-table remap with foreign-key rewriting across every child table — the single most expensive migration mistake available to you.
- Timestamps. UTC epoch-milliseconds everywhere, `created_at`/`updated_at` on every row.
- Deletion. Tombstones (`deleted_at`), never hard deletes. A hard-deleted row cannot be replicated; the remote peer will happily resurrect it.
- Ownership. A `user_id` column present from day one, populated with a sentinel (`local`). Backfilling a `NOT NULL` owner column onto a live schema later is tedious; having the column already there makes first-auth a one-line `UPDATE`.
- Schema shape. Drift's SQL DDL transfers to Postgres with type substitutions only (`TEXT`→`uuid`/`text`, `INTEGER`→`bigint`/`timestamptz`).

**What costs real effort regardless:**

1. **The sync engine itself** — 2–4 weeks solo, honestly. Change-tracking, push/pull batching, cursor management, conflict resolution, and the state machine for partial failure. There is no way to make this free; you can only choose when to pay.
2. **Auth and account bootstrapping** — sign-up, sign-in, token refresh, session restoration, and the one-time claim of existing local data by a newly created account. That last step is fiddly and easy to get wrong (double-claim, orphaned local data).
3. **Media reconciliation** — every existing local file needs uploading, with a `remote_url` written back and a local-path-vs-remote-URL resolution strategy in the UI. Backfilling a year of videos over a domestic connection is an overnight job with a resumable uploader.
4. **Multi-writer semantics** — the moment a second device exists, "which edit wins" becomes a product question, not a technical one.

**What leaks into the domain if you're careless — the real answer to your "zero changes" requirement:**

These are the actual failure points of a naive repository abstraction. Each one is a place where a backend forces a change into supposedly-insulated layers:

| Leak | Why it happens | Mitigation from day one |
|---|---|---|
| Error taxonomy | Local storage cannot produce a network timeout. If `Failure` has no network variants, every `switch` in the presentation layer becomes non-exhaustive when you add them. | Define the full `Failure` hierarchy now, including `NetworkFailure`, `AuthFailure`, `ConflictFailure`. Handle them in the UI as unreachable-but-handled branches. Dart 3 exhaustiveness checking then enforces this for you. |
| Transactionality | Local SQLite gives you ACID across `workout_sessions` + `exercise_logs` in one transaction. A REST backend gives you per-request atomicity. Code that assumes multi-entity atomicity breaks. | Keep writes local and atomic forever. Sync pushes are eventually-consistent by design and never sit on the UI path. |
| Reactivity | `Drift.watch()` returns a stream that updates on every write. Supabase Realtime has different delivery semantics, ordering, and reconnection behaviour. Swapping one for the other rewrites every screen. | **Never subscribe the UI to a remote stream.** Sync writes into Drift; the UI watches Drift. One reactive source, permanently. |
| Latency assumptions | Local reads are sub-millisecond, so it is tempting to read in `build()` or per-list-item. Those patterns are catastrophic against a network. | Enforce the local-read-model rule and this never arises. |
| Pagination | Local queries can be unbounded. Remote ones can't. | Paginate from day one even though you don't need to. Cheap insurance. |
| Query authorisation | Every remote query needs `user_id` scoping. Retrofitting this across a query layer is invasive and easy to get partially wrong. | `user_id` in the schema and in every repository query from day one, even when it's always `'local'`. |
| Offline mutation queue | If the UI awaits writes, adding a network makes every write a potential hang. | Writes are local and synchronous-feeling; the queue is a background concern the UI never sees. |

Adopt the mitigations and the leak surface collapses to near zero. Skip them, and the repository interface becomes a fig leaf — the interface stays stable while every implementation detail behind it forces changes in front of it.

### 1.4 Where Strategy B genuinely wins

For completeness, and because I don't want this read as a one-sided recommendation:

- **If you intend other users within 6 months.** Multi-user changes everything — auth is mandatory, RLS is mandatory, and retrofitting tenancy is genuinely painful. Build B.
- **If data loss is unacceptable and you won't build export.** Cloud storage is real backup. A local DB with no export is one dropped phone from zero.
- **If you want to run analytics off-device**, e.g. heavy aggregation over years of heart-rate samples. Postgres is much better at this than SQLite on a phone.
- **If you're building this partly to keep backend skills sharp** — a legitimate motivation, and one worth stating out loud if it applies. Optimising for shipping speed is the wrong objective function if the actual goal is practice.
- **Supabase specifically narrows the gap.** Auth + Postgres + Storage + RLS out of the box is genuinely a few days, not a few weeks, and it removes most of the "backend babysitting" objection. If you go B, go Supabase; do not hand-roll Go/FastAPI + S3 for a single-user app.

### 1.5 Verdict

**Strategy A+ — local-first with sync-ready primitives.**

Rationale, ranked:

1. **The device-anchored constraint dominates.** Health and media pipelines run on-device under both strategies. Strategy B doesn't remove work; it adds a tier on top of work you must do anyway.
2. **Offline is a hard requirement, not a nice-to-have.** Gym basements. Any cloud-first design still needs a local store and a sync layer, which is Strategy A plus extra work — done earlier, with less information.
3. **Solo-developer throughput is the binding constraint.** The failure mode for personal projects is abandonment before the habit-forming feature ships. Strategy A gets a usable workout logger into your hands in week one; Strategy B gets you an auth screen.
4. **The migration cost is bounded and front-loadable.** Sections 1.3 and 1.6 reduce it to "write a sync module", which is a self-contained, well-understood piece of work — not a refactor.
5. **You retain the option to never migrate.** If, after a year, one device and a nightly export are sufficient, you've spent zero on a backend you didn't need. Strategy B has no equivalent escape hatch.

**Two non-negotiable conditions on this verdict:**

- **Ship export/import in Phase 1, not Phase 4.** Zip the SQLite file plus the media directory and hand it to the share sheet. Two days of work. Without this, the durability argument for Strategy B becomes correct and the verdict flips.
- **Apply every primitive in Section 1.6 from the first commit.** They cost nothing now and are expensive to retrofit. Skipping them is what turns a two-week sync module into a two-month rewrite.

### 1.6 The sync-ready primitives (apply from commit one)

Every synchronisable table carries:

```sql
id            TEXT    PRIMARY KEY,          -- UUIDv7, client-generated
user_id       TEXT    NOT NULL DEFAULT 'local',
created_at    INTEGER NOT NULL,             -- UTC epoch millis
updated_at    INTEGER NOT NULL,             -- UTC epoch millis, bumped on every write
deleted_at    INTEGER,                      -- tombstone; NULL = live
sync_state    INTEGER NOT NULL DEFAULT 0,   -- 0 pending, 1 syncing, 2 synced, 3 conflict
server_rev    INTEGER,                      -- optimistic concurrency token from remote
device_id     TEXT    NOT NULL              -- provenance, LWW tie-break
```

Why UUIDv7 rather than v4: it is time-ordered, so it behaves well as a B-tree primary key on both SQLite and Postgres, avoids the index-fragmentation penalty of random UUIDs, and gives you a free creation-order sort. Generate client-side; never wait on a server for an identifier.

Additionally: all reads filter `deleted_at IS NULL`; all writes bump `updated_at` and reset `sync_state` to pending. Enforce both in a single base DAO so it is impossible to forget.

---

## 2. Software Architecture

### 2.1 Layering

```
lib/
├── core/                        # cross-cutting, no feature knowledge
│   ├── error/                   # Failure hierarchy, Result type
│   ├── sync/                    # SyncCoordinator, change queue, backoff
│   ├── storage/                 # path resolution, storage budget
│   └── util/                    # uuid, clock (injectable — critical for tests)
│
├── domain/                      # PURE DART. No Flutter, no Drift, no JSON.
│   ├── entities/                # WorkoutSession, ExerciseLog, MediaAttachment, HealthSnapshot
│   ├── value_objects/           # Streak, Weight, Rpe, HeartRateZone
│   ├── repositories/            # abstract interfaces ONLY
│   └── usecases/                # LogWorkout, ComputeStreak, SyncHealthData
│
├── data/
│   ├── local/                   # Drift database, tables, DAOs
│   ├── remote/                  # (Phase 4) API clients — absent until then
│   ├── health/                  # HealthConnect / HealthKit / FitbitWebApi sources
│   ├── media/                   # capture, compression, thumbnailing
│   ├── dto/                     # persistence/wire models + mappers
│   └── repositories/            # concrete implementations
│
└── presentation/
    ├── providers/               # Riverpod providers
    ├── screens/
    └── widgets/
```

The dependency rule: `presentation → domain ← data`. The domain imports nothing. If `domain/` has a single `package:drift` or `package:flutter` import, the abstraction has already failed — enforce this with a lint rule or a CI grep, because it *will* drift otherwise.

One structural note that matters more than the folder layout: **`data/remote/` does not exist until Phase 4, and its absence should not be visible from anywhere else.** If any file outside `data/` needs to know whether a remote source exists, the seam is in the wrong place.

### 2.2 The rule that makes migration cheap

```
              ┌─────────────────────────────────────────┐
              │            Presentation                 │
              │   watches ONLY local reactive streams   │
              └────────────────────┬────────────────────┘
                                   │ Stream<T>
              ┌────────────────────▼────────────────────┐
              │        Repository (domain iface)        │
              │   reads: local only.  writes: local.    │
              └────────────────────┬────────────────────┘
                                   │
              ┌────────────────────▼────────────────────┐
              │          Drift (SQLite) — the           │
              │       single source of truth for        │
              │              all reads                  │
              └────────────────────▲────────────────────┘
                                   │ writes in
              ┌────────────────────┴────────────────────┐
              │   SyncCoordinator (Phase 4, background)  │
              │   pull → upsert local; push ← pending    │
              └────────────────────▲────────────────────┘
                                   │
                            ┌──────┴──────┐
                            │   Remote    │
                            └─────────────┘
```

The UI never touches the remote tier. Sync is a *peer* of the repository, not a layer beneath it. This is the whole trick.

### 2.3 Domain contracts

```dart
// ── core/error/failure.dart ────────────────────────────────────────────
// Defined in full NOW, including variants unreachable in Phase 1.
// Dart 3 exhaustiveness then guarantees the UI already handles them.

sealed class Failure {
  const Failure(this.message);
  final String message;
}

final class StorageFailure   extends Failure { const StorageFailure(super.m); }
final class NotFoundFailure  extends Failure { const NotFoundFailure(super.m); }
final class ValidationFailure extends Failure { const ValidationFailure(super.m); }
final class PermissionFailure extends Failure { const PermissionFailure(super.m); }
final class HealthSourceFailure extends Failure { const HealthSourceFailure(super.m); }
final class MediaFailure     extends Failure { const MediaFailure(super.m); }
// Unreachable in Phase 1 — deliberately declared anyway:
final class NetworkFailure   extends Failure { const NetworkFailure(super.m); }
final class AuthFailure      extends Failure { const AuthFailure(super.m); }
final class ConflictFailure  extends Failure {
  const ConflictFailure(super.m, {required this.localRev, required this.remoteRev});
  final int localRev;
  final int remoteRev;
}

// ── core/error/result.dart ─────────────────────────────────────────────

sealed class Result<T> {
  const Result();
}
final class Ok<T>  extends Result<T> { const Ok(this.value);   final T value; }
final class Err<T> extends Result<T> { const Err(this.failure); final Failure failure; }
```

```dart
// ── domain/repositories/workout_repository.dart ────────────────────────
// Note what is ABSENT: no sync(), no refresh(), no isOnline, no fetch().
// Those are sync-tier concerns. Their absence is what keeps this stable
// across the Phase 4 transition.

abstract interface class WorkoutRepository {
  /// Reactive read. Emits on every local mutation, including those
  /// written by the sync coordinator. Always local-backed.
  Stream<List<WorkoutSession>> watchSessions({
    required DateTime from,
    required DateTime to,
    int limit = 100,        // paginate from day one, even locally
    int offset = 0,
  });

  Stream<WorkoutSession?> watchSession(String id);

  Future<Result<WorkoutSession>> getSession(String id);

  /// Local, atomic, immediate. Returns before any network involvement.
  Future<Result<WorkoutSession>> upsertSession(WorkoutSession session);

  /// Tombstone, never a hard delete.
  Future<Result<void>> deleteSession(String id);

  Future<Result<List<WorkoutSession>>> sessionsForStreak({
    required DateTime since,
  });
}
```

```dart
// ── data/local/workout_local_data_source.dart ──────────────────────────
// Sync-aware surface, used only by the repository impl and the coordinator.

abstract interface class WorkoutLocalDataSource {
  Stream<List<WorkoutSessionRow>> watch({required DateTime from, required DateTime to,
                                          int limit, int offset});
  Future<void> upsert(WorkoutSessionRow row, {required SyncState state});
  Future<void> upsertFromRemote(WorkoutSessionRow row, int serverRev);
  Future<List<WorkoutSessionRow>> pendingChanges({int limit = 50});
  Future<void> markSynced(String id, int serverRev);
  Future<void> markConflict(String id);
}

// ── data/remote/workout_remote_data_source.dart ────────────────────────
// PHASE 4 ONLY. Written as an interface now purely to prove the seam holds;
// no implementation exists until the sync module is built.

abstract interface class WorkoutRemoteDataSource {
  Future<List<WorkoutSessionRow>> pullSince(DateTime cursor, {int limit = 200});
  Future<PushOutcome> push(List<WorkoutSessionRow> batch);
}
```

```dart
// ── data/repositories/workout_repository_impl.dart ─────────────────────
// THIS FILE DOES NOT CHANGE IN PHASE 4. That is the point.
// It has no reference to WorkoutRemoteDataSource at all.

final class WorkoutRepositoryImpl implements WorkoutRepository {
  WorkoutRepositoryImpl(this._local, this._clock, this._uuid, this._deviceId);

  final WorkoutLocalDataSource _local;
  final Clock _clock;                    // injectable — do not call DateTime.now() directly
  final UuidV7 _uuid;
  final String _deviceId;

  @override
  Stream<List<WorkoutSession>> watchSessions({
    required DateTime from, required DateTime to, int limit = 100, int offset = 0,
  }) =>
      _local.watch(from: from, to: to, limit: limit, offset: offset)
            .map((rows) => rows.map(WorkoutSessionMapper.toEntity).toList());

  @override
  Future<Result<WorkoutSession>> upsertSession(WorkoutSession session) async {
    try {
      final now = _clock.nowUtcMillis();
      final row = WorkoutSessionMapper.toRow(
        session.id.isEmpty ? session.copyWith(id: _uuid.generate()) : session,
        updatedAt: now,
        deviceId: _deviceId,
      );
      await _local.upsert(row, state: SyncState.pending);
      return Ok(WorkoutSessionMapper.toEntity(row));
    } on DriftRemoteException catch (e) {
      return Err(StorageFailure(e.toString()));
    }
  }
  // ...
}
```

Two details in there that are easy to skip and painful to retrofit:

- **`Clock` is injected.** Streak logic is date-boundary logic, which is the single most bug-prone part of a habit app (DST, timezone travel, "does a 1 a.m. workout count as yesterday?"). You cannot test any of it deterministically if `DateTime.now()` is called inline. Decide your day-boundary rule explicitly — I'd suggest a configurable "day starts at 04:00 local" to handle late-night sessions sanely.
- **`_deviceId` is threaded through writes** even though there's one device. It's the tie-break for last-writer-wins later, and it costs a column now.

### 2.4 State management

**Recommendation: Riverpod (with `riverpod_generator` / `@riverpod` codegen).**

Rationale over Bloc, for this specific project: compile-time-safe dependency injection without `BuildContext`, trivially overridable providers in tests (swap `WorkoutRepository` for a fake in one line), `StreamProvider` maps 1:1 onto Drift's `watch()`, and `AsyncValue` gives you loading/error/data as an exhaustive sealed type rather than hand-rolled states. Bloc is a perfectly good choice and its event-sourcing discipline is valuable on a team — but the ceremony-to-value ratio is wrong for a solo project, and Bloc's strength (explicit, auditable event streams across many contributors) doesn't apply here.

```dart
@riverpod
Stream<List<WorkoutSession>> recentSessions(RecentSessionsRef ref) {
  final repo = ref.watch(workoutRepositoryProvider);
  final now = ref.watch(clockProvider).nowUtc();
  return repo.watchSessions(from: now.subtract(const Duration(days: 90)), to: now);
}
```

**Keeping async work off the UI thread.** Three distinct mechanisms, and conflating them is a common mistake:

1. **Long-running background work** (health sync, media upload) belongs in a platform-scheduled worker, not a Notifier. `workmanager` for Android (`WorkManager`), `BGTaskScheduler` on iOS. These survive app termination; a Notifier does not. Note iOS's scheduling is opportunistic and non-guaranteed — never design a feature that depends on iOS background execution firing on time.
2. **CPU-bound work** (video compression, thumbnail generation, large aggregations) belongs in an isolate: `Isolate.run()` for one-shot work, a long-lived isolate for the media queue. Drift supports running the database on a background isolate — do that from the start, because retrofitting it means auditing every query.
3. **Foreground async** (a Health Connect read triggered by pull-to-refresh) is a normal `AsyncNotifier` with `AsyncValue` states.

The sync/upload queue itself should be a `Notifier` that *observes* a persistent queue table rather than holding queue state in memory. Anything in memory is lost when the OS kills the app mid-upload, which it will.

---

## 3. Health & Wearable Data Integration Blueprint

### 3.1 The actual pipelines (not the one in the brief)

**Android — works, with caveats:**

```
Fitbit device ──BLE──> Fitbit app ──writes──> Health Connect ──reads──> Your app
                       (sync lag:              (on-device store)
                        15 min – hours)
```

Fitbit's Android app writes to Health Connect. <cite index="12-1">Fitbit can write data such as workouts, sleep, and heart rate to Health Connect, and the user chooses which data types Fitbit writes.</cite> The available types reported at rollout were Distance, Elevation gained, Exercise, Floors climbed, Heart rate, Sleep, Steps, and Total calories burned.

Three caveats that affect your feature list directly:

- **Fitbit is write-only to Health Connect.** <cite index="14-1">Fitbit cannot read data other apps have written to Health Connect.</cite> No round-tripping your logged strength sessions back into Fitbit.
- **You asked for *active* calories; Fitbit writes *total* calories.** Read both `ActiveCaloriesBurnedRecord` and `TotalCaloriesBurnedRecord`, prefer active where present, fall back to total minus an estimated BMR, and record which you used in `HealthSnapshot.source_metadata`. Don't silently mix the two — the numbers differ by ~1,500 kcal/day and will destroy any trend chart.
- **Heart rate zones are not a Health Connect data type.** <cite index="14-1">Fitbit-exclusive metrics such as Active Zone Minutes are not supported by Health Connect.</cite> Derive zones client-side from `HeartRateRecord` samples against a user-configured max HR. Store the zone model version in your snapshot so recalculation is possible when the user updates their max HR.
- Some data types <cite index="16-1">require a Google Account to sync with Health Connect</cite>. If the Fitbit account hasn't been migrated to Google, some types silently won't appear.

**iOS — does not work as specified:**

```
Fitbit device ──BLE──> Fitbit app ──✗ NO PATH ✗──> HealthKit
```

<cite index="27-1">Fitbit and Apple Health do not sync natively; the practical workaround is a bridge app that pulls from Fitbit and writes into Apple Health, because Apple Health stores data in HealthKit while Fitbit sits in Google's ecosystem, and platform boundaries prevent automatic flow.</cite> Fitbit has stated it has no plans to integrate with HealthKit.

Your three options, in my order of preference:

**(a) Fitbit Web API directly — recommended.** OAuth 2.0 with PKCE, server-side-free, works identically on both platforms. Register your application as type **Personal**, which grants intraday (fine-grained) heart-rate and activity access for your own account without the partner approval process required for public apps. Rate limit is 150 requests/hour/user, which is ample for a daily sync. Verify the current application-type policy on the Fitbit developer portal before building — this is the detail most likely to have shifted.

**(b) Third-party bridge app** (SyncFit, Sync Solver et al.) writes into HealthKit; you read HealthKit normally. Zero code, but it makes your app's core value dependent on a paid third-party app you don't control, with daily-granularity data only in most cases.

**(c) iOS ships without Fitbit data**, using iPhone/Apple Watch HealthKit data only. Legitimate if you'd wear a Watch on iOS anyway.

**Architectural consequence, whichever you pick:** the source abstraction must be three-way from the start, not two-way.

```dart
abstract interface class HealthDataSource {
  String get sourceId;                                   // 'health_connect' | 'healthkit' | 'fitbit_api'
  Future<Result<bool>> isAvailable();
  Future<Result<PermissionStatus>> requestPermissions(Set<HealthMetric> metrics);
  Future<Result<HealthSyncResult>> read({
    required DateTime from,
    required DateTime to,
    String? changeCursor,                                 // HC changes token / Fitbit ETag
  });
}
```

`FitbitWebApiSource` is then equally usable on Android as a backfill for history older than Health Connect retains, which is a genuine bonus rather than pure iOS tax.

### 3.2 Android permission lifecycle (Android 14+)

Health Connect is part of the platform on Android 14+ and an installable APK on Android 9–13. Handle both: check availability via `HealthConnectClient.getSdkStatus()` and route the user to the Play Store install flow when the SDK reports `SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED`.

Manifest declarations:

```xml
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_EXERCISE"/>
<uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>
<uses-permission android:name="android.permission.health.READ_TOTAL_CALORIES_BURNED"/>
<uses-permission android:name="android.permission.health.READ_DISTANCE"/>
<uses-permission android:name="android.permission.health.READ_SLEEP"/>
```

Two additional permissions are separate declarations and commonly missed: <cite index="17-1">reading data while the app is in the background requires `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND`, and reading data older than 30 days requires `android.permission.health.READ_HEALTH_DATA_HISTORY`.</cite> Your habit engine needs both — background for scheduled sync, history for streak backfill on install.

The rationale intent must be declared or permission requests fail opaquely:

```xml
<!-- Android 14+ (API 34+) -->
<activity-alias
    android:name="ViewPermissionUsageActivity"
    android:exported="true"
    android:targetActivity=".MainActivity"
    android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
  <intent-filter>
    <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>
    <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>
  </intent-filter>
</activity-alias>

<!-- Below API 34 -->
<intent-filter>
  <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>
</intent-filter>
```

**Schedule risk worth flagging now:** <cite index="15-1">before publishing to the Play Store you must complete a health apps declaration covering your data use and each Health Connect data type you access, or users will hit an error where the app cannot access those types because they require special approval.</cite> This requires a hosted privacy policy and is a review process with a turnaround measured in days. If this app is only ever sideloaded onto your own device, the declaration doesn't apply — a genuine simplification worth taking deliberately rather than by accident. If you intend to publish, even to a closed testing track, start the declaration in Phase 2, not Phase 4.

Permissions are also **revocable at any time and are auto-revoked after extended non-use**. Never cache "granted" as durable state; re-check before every read and degrade gracefully to a "reconnect Fitbit" card rather than an error dialog.

### 3.3 Flutter package selection

Use **`health`** (currently 13.3.1, `carp-dk/carp-health-flutter`) — the only mature package wrapping both HealthKit and Health Connect behind one API. Note the risk profile honestly: single maintainer, ~19k weekly downloads, and Google Fit support was removed in v11 following the Fit API turndown. It's the right choice, but wrap it behind your own `HealthDataSource` interface (Section 3.1) so the blast radius of it going unmaintained is one file.

The Health Connect Jetpack library itself is at stable `1.1.0` (`androidx.health.connect:connect-client`), which is what `health` binds against on Android. If you need Health Connect features the package hasn't exposed — the Changes API, in particular — a thin platform channel to `connect-client` is a reasonable escape hatch and better than forking.

### 3.4 Deduplication

This is where health integrations usually go wrong. The rules:

1. **Never key on time windows.** Overlapping reads will duplicate.
2. **Key on the source record identity.** Health Connect assigns each record a stable `Metadata.id`, with `dataOrigin.packageName` identifying the writing app and `lastModifiedTime` for change detection. Store `(source_id, source_record_id)` with a unique index and upsert on it. HealthKit's equivalent is `HKObject.uuid`; Fitbit Web API gives you `logId` for activities.
3. **Use the Changes API for incremental reads.** `getChangesToken()` → persist → `getChanges(token)` on each sync. Vastly cheaper than re-reading a window and inherently dedup-safe. The token expires after ~30 days of non-use; on `ChangesTokenExpired`, fall back to a full windowed re-read and re-issue a token. Handle this path explicitly — it *will* fire after any holiday.
4. **Aggregate rather than pulling raw samples where you can.** `aggregate()` for daily step/calorie totals. Pulling raw heart-rate samples at 1 Hz for a year is millions of rows on a phone. Pull raw HR only for the duration of logged exercise sessions, aggregate everything else.
5. **Prefer sources deterministically when several write the same type.** Fitbit, the phone's own step counter, and Google Health may all write steps. Define a priority order (`fitbit > healthkit_device > phone`) and record the winner in `source_metadata`, rather than summing them.
6. **Match Health Connect `ExerciseSessionRecord`s to your own logged sessions by time overlap** (>60% overlap and same day), then link rather than duplicate. Store the link so the user can manually unlink a bad match.

**Error handling:** treat health reads as always-fallible and never blocking. A failed sync writes a `HealthSyncAttempt` row (timestamp, source, outcome, error) and leaves the UI showing last-known-good data with a subtle staleness indicator. Exponential backoff on repeated failure, capped at ~6 hours. Never show a modal error for a background sync failure — it trains you to dismiss dialogs.

---

## 4. Data Models & Schemas

Shown as SQL because Drift is SQL-native and the point is that the two schemas are near-identical. All tables carry the Section 1.6 primitives; they're written out in full on the first table and elided afterwards for readability.

### 4.1 Local (Drift / SQLite)

```sql
CREATE TABLE workout_sessions (
  -- sync primitives
  id             TEXT    NOT NULL PRIMARY KEY,     -- UUIDv7
  user_id        TEXT    NOT NULL DEFAULT 'local',
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER,
  sync_state     INTEGER NOT NULL DEFAULT 0,
  server_rev     INTEGER,
  device_id      TEXT    NOT NULL,
  -- domain
  started_at     INTEGER NOT NULL,                 -- UTC epoch ms
  ended_at       INTEGER,
  local_date     TEXT    NOT NULL,                 -- 'YYYY-MM-DD' in the user's day-boundary
  tz_offset_min  INTEGER NOT NULL,                 -- offset at capture; needed for travel
  workout_type   TEXT    NOT NULL,                 -- enum: strength|cardio|mobility|sport|other
  title          TEXT,
  notes          TEXT,
  perceived_effort INTEGER,                        -- session RPE 1-10
  status         TEXT    NOT NULL DEFAULT 'completed', -- planned|in_progress|completed|skipped
  health_snapshot_id TEXT REFERENCES health_snapshots(id)
);

CREATE INDEX ix_sessions_local_date ON workout_sessions(user_id, local_date)
  WHERE deleted_at IS NULL;
CREATE INDEX ix_sessions_pending    ON workout_sessions(sync_state)
  WHERE sync_state = 0;
```

`local_date` and `tz_offset_min` are the two columns people forget. Streaks are computed against the user's *local* day, and deriving that from a UTC timestamp after the fact is impossible if the user has travelled. Store it at write time. `status = 'skipped'` is what makes missed-session analytics queryable rather than inferred from absence.

```sql
CREATE TABLE exercise_logs (
  id, user_id, created_at, updated_at, deleted_at, sync_state, server_rev, device_id, -- as above
  session_id     TEXT    NOT NULL REFERENCES workout_sessions(id),
  exercise_id    TEXT    NOT NULL REFERENCES exercises(id),
  order_index    INTEGER NOT NULL,
  set_index      INTEGER NOT NULL,
  reps           INTEGER,
  weight_kg      REAL,                             -- always store SI; convert at display
  duration_sec   INTEGER,                          -- for time-based work
  distance_m     REAL,
  rpe            REAL,                             -- 1.0–10.0, half-steps
  is_warmup      INTEGER NOT NULL DEFAULT 0,
  rest_sec       INTEGER,
  notes          TEXT
);
CREATE UNIQUE INDEX ux_exercise_logs_slot
  ON exercise_logs(session_id, order_index, set_index) WHERE deleted_at IS NULL;

-- Reference table: your exercise catalogue. Not user data, but user-extensible.
CREATE TABLE exercises (
  id, created_at, updated_at, deleted_at,           -- no user_id: seeded catalogue
  name           TEXT NOT NULL,
  category       TEXT NOT NULL,                     -- push|pull|legs|core|cardio
  primary_muscle TEXT,
  equipment      TEXT,
  is_custom      INTEGER NOT NULL DEFAULT 0
);
```

Storing one row per set rather than a JSON blob per exercise is deliberate: it makes progression queries (`MAX(weight_kg) per exercise per week`) plain SQL, and it makes per-row last-writer-wins conflict resolution possible later. A JSON blob forces document-level LWW, where editing set 3 on one device clobbers set 5 edited on another. This is the strongest concrete argument for Drift over a document store.

```sql
CREATE TABLE media_attachments (
  id, user_id, created_at, updated_at, deleted_at, sync_state, server_rev, device_id,
  session_id       TEXT REFERENCES workout_sessions(id),
  exercise_log_id  TEXT REFERENCES exercise_logs(id),
  media_type       TEXT    NOT NULL,               -- photo|video
  relative_path    TEXT    NOT NULL,               -- 'media/2026/09/<uuid>.mp4'  ← NEVER absolute
  thumb_rel_path   TEXT,
  mime_type        TEXT    NOT NULL,
  size_bytes       INTEGER NOT NULL,
  width            INTEGER,
  height           INTEGER,
  duration_ms      INTEGER,
  checksum_sha256  TEXT    NOT NULL,               -- dedup + upload integrity
  capture_state    TEXT    NOT NULL,               -- captured|compressing|ready|failed
  remote_url       TEXT,                           -- NULL until uploaded
  upload_state     TEXT    NOT NULL DEFAULT 'local_only',
  upload_offset    INTEGER NOT NULL DEFAULT 0,     -- resumable upload cursor
  evicted_at       INTEGER                         -- local original deleted, remote retained
);
```

**`relative_path`, not absolute path.** On iOS the app container UUID changes on reinstall and on restore-from-backup, so every absolute path in your database silently breaks. Store paths relative to the documents directory and resolve at read time through a single `MediaPathResolver`. This bug is invisible in development and total in production.

```sql
CREATE TABLE health_snapshots (
  id, user_id, created_at, updated_at, deleted_at, sync_state, server_rev, device_id,
  local_date         TEXT    NOT NULL,
  window_start       INTEGER NOT NULL,
  window_end         INTEGER NOT NULL,
  steps              INTEGER,
  active_kcal        REAL,
  total_kcal         REAL,
  calorie_basis      TEXT,                          -- 'active'|'derived_from_total'
  distance_m         REAL,
  avg_hr             INTEGER,
  peak_hr            INTEGER,
  resting_hr         INTEGER,
  zone_model_version INTEGER,                       -- recompute trigger when max HR changes
  zone_seconds_json  TEXT,                          -- {"z1":420,"z2":1180,...}
  sleep_minutes      INTEGER,
  -- provenance
  source_id          TEXT    NOT NULL,              -- health_connect|healthkit|fitbit_api
  source_package     TEXT,                          -- e.g. com.fitbit.FitbitMobile
  source_record_id   TEXT,                          -- HC Metadata.id / HKObject.uuid / Fitbit logId
  source_modified_at INTEGER,
  ingested_at        INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_health_dedup
  ON health_snapshots(source_id, source_package, source_record_id)
  WHERE source_record_id IS NOT NULL;
```

That unique index is the deduplication mechanism from Section 3.4, enforced by the database rather than by application logic you might forget to run.

Plus two operational tables:

```sql
CREATE TABLE sync_cursors (       -- HC changes token, Fitbit ETag, remote pull cursor
  source_id TEXT PRIMARY KEY, cursor TEXT, updated_at INTEGER NOT NULL,
  last_success_at INTEGER, consecutive_failures INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE habit_definitions (  -- the habit engine's config, user-editable
  id, created_at, updated_at, deleted_at,
  name TEXT NOT NULL,
  cadence TEXT NOT NULL,          -- 'n_per_week' | 'specific_days' | 'daily'
  target_count INTEGER,
  target_days_json TEXT,          -- [1,3,5]
  grace_days INTEGER NOT NULL DEFAULT 0,   -- streak forgiveness
  active_from TEXT NOT NULL, active_to TEXT
);
```

`grace_days` is a product decision worth making early: a streak that breaks on one missed session is a streak that gets abandoned. One rest-day-per-week forgiveness makes the mechanic survive contact with real life.

### 4.2 Cloud (PostgreSQL)

Same shape. The diff is the point:

```sql
CREATE TABLE workout_sessions (
  id              uuid        PRIMARY KEY,                    -- was TEXT
  user_id         uuid        NOT NULL REFERENCES auth.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),         -- was INTEGER epoch
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  server_rev      bigint      NOT NULL DEFAULT 1,             -- authoritative here
  device_id       text        NOT NULL,
  started_at      timestamptz NOT NULL,
  ended_at        timestamptz,
  local_date      date        NOT NULL,
  tz_offset_min   smallint    NOT NULL,
  workout_type    text        NOT NULL,
  title           text,
  notes           text,
  perceived_effort smallint   CHECK (perceived_effort BETWEEN 1 AND 10),
  status          text        NOT NULL DEFAULT 'completed'
);
-- sync_state is a CLIENT concept and does not exist server-side.

CREATE INDEX ix_sessions_pull ON workout_sessions (user_id, updated_at)
  INCLUDE (id);                            -- serves the incremental pull query

ALTER TABLE workout_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON workout_sessions
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE TRIGGER bump_rev BEFORE UPDATE ON workout_sessions
  FOR EACH ROW EXECUTE FUNCTION increment_server_rev();
```

Type substitutions and RLS, essentially. `sync_state` drops out (client-only); `server_rev` becomes server-authoritative and trigger-maintained. Media moves to object storage with `remote_url` holding an object key rather than a URL — store the key, sign on demand, never persist a signed URL.

**Pull query** (the one the index above exists for):

```sql
SELECT * FROM workout_sessions
WHERE user_id = $1 AND updated_at > $2
ORDER BY updated_at, id
LIMIT 200;
```

Cursor on `(updated_at, id)`, not `updated_at` alone — ties at millisecond resolution will silently skip rows otherwise.

---

## 5. Media Pipeline & Storage Optimisation

### 5.1 Capture and compression targets

| Asset | Capture | Stored format | Target | Approx size |
|---|---|---|---|---|
| Form-check photo | Native camera | JPEG q80, longest edge 1920px, EXIF stripped except orientation | < 500 KB | ~300 KB |
| Equipment/setup photo | Native camera | JPEG q75, longest edge 1280px | < 250 KB | ~150 KB |
| Thumbnail (both) | Derived | WebP q70, 320px | < 25 KB | ~15 KB |
| Form-check video | 720p30 | H.264 High, ~2.2 Mbps, AAC 96 kbps mono | **60 s hard cap** | ~17 MB/min |
| Video thumbnail | Frame at 1s | WebP q70, 320px | < 25 KB | ~15 KB |

**The 60-second cap is the highest-leverage decision in this section.** A form check is 3 reps, not a whole set. Capping duration at capture eliminates almost every downstream storage problem, makes upload times tolerable, and is a one-line constraint in the camera controller. Enforce it in the UI (auto-stop with a countdown ring), not by trimming afterwards.

HEVC/H.265 would cut video size ~40%, but costs you playback compatibility, share-sheet friction, and slower software-encode fallback on older Android hardware. At one minute per clip the absolute saving is ~7 MB — not worth the compatibility surface. Stay on H.264. Revisit only if you lift the duration cap.

**Tooling caveat worth verifying before you commit:** `ffmpeg_kit_flutter` was retired by its maintainer in early 2025 and its prebuilt binaries were pulled from the hosted repositories, which broke builds for many projects. Do not architect around it without checking its current status. Preferred alternatives: platform-native encoding (`MediaCodec` on Android, `AVAssetExportSession` on iOS) behind a small platform channel — more code, but no supply-chain risk and hardware-accelerated on both platforms. For photos, `flutter_image_compress` is stable and sufficient.

### 5.2 Storage layout and lifecycle

```
<app_documents>/
  media/
    2026/09/<uuid>.jpg
    2026/09/<uuid>.mp4
  thumbs/
    2026/09/<uuid>.webp
  export/          ← transient, cleared on launch
<app_cache>/
  compress/        ← in-flight compression scratch; OS may reclaim, and that's fine
```

Date-partitioned directories keep any single directory small enough for fast enumeration and make manual inspection and bulk deletion trivial.

**Pipeline states**, persisted in `media_attachments.capture_state`, because the app will be killed mid-compression:

```
captured → compressing → ready → (uploading → uploaded → evicted)
              ↓
           failed  → retry (max 3) → orphan sweep
```

**Cleanup, in priority order:**

1. **Orphan sweep on launch.** Walk `media/` and `thumbs/`, delete any file with no matching live DB row. This catches crash-during-compression debris, which is the main source of unexplained storage growth.
2. **Cache directory purge on launch.** Anything in `compress/` older than an hour is dead.
3. **Storage budget with a visible number.** Default 2 GB, surfaced in settings as "Media: 1.2 GB of 2 GB". When exceeded, evict originals oldest-first — **but only where `remote_url IS NOT NULL`** (post-Phase 4) or after prompting the user (pre-Phase 4). Never evict silently in the local-only phase; that's data loss.
4. **Thumbnails are never evicted.** At ~15 KB, a decade of them is under 40 MB, and keeping them means the history browsing experience never degrades into grey boxes.
5. **Cascade on session delete** — tombstoning a session queues its media for deletion after the sync horizon (say 30 days), not immediately, so a remote peer can observe the tombstone first.

### 5.3 Upload (Phase 4)

- **Resumable, not monolithic.** A 17 MB video over a flaky mobile connection will fail. Use TUS (Supabase Storage supports it natively) or S3/R2 multipart with ~5 MB parts. Persist `upload_offset` per attachment so a resumed upload doesn't restart.
- **Presigned URLs, requested just in time.** The client asks the backend for a signed PUT URL when the upload starts, with a short TTL (15 min) scoped to one object key. Never store signed URLs in the database — store the object key and sign on demand for reads too.
- **Path convention:** `{user_id}/{yyyy}/{MM}/{attachment_id}.{ext}`. User-prefixed so a storage-level policy can enforce ownership by path.
- **Integrity:** send the SHA-256 you already computed at capture; verify server-side. This also gives you free deduplication if the same clip is somehow attached twice.
- **Scheduling policy:** upload only on unmetered networks by default, with a per-item "upload now" override. Battery-aware, deferrable work — exactly what `WorkManager` constraints exist for.
- **Thumbnails upload first**, eagerly and on any connection. They're 15 KB, and having them remote means a new device shows a complete-looking history immediately while originals stream in behind.

---

## 6. Phased Implementation Roadmap

Sprints are notional two-week solo blocks. Exit criteria matter more than the timeboxes.

### Phase 1 — Local foundation, UI shell, media capture (Sprints 1–3)

*Goal: you are logging real workouts by the end of sprint 2.*

- **S1.1** Project scaffold, layer enforcement lint, Drift setup on a background isolate, Riverpod codegen, `Clock`/`UuidV7` injectables.
- **S1.2** Full schema with Section 1.6 primitives. Migration harness and a round-trip migration test from the very first version — not later.
- **S1.3** Domain entities, `Failure` hierarchy (complete, including network variants), repository interfaces, local data sources, mappers.
- **S1.4** Workout logging UI: session start/stop, exercise picker with a seeded catalogue, set-by-set entry, notes. This is the core loop — make it fast to use one-handed with sweaty fingers, because that's the actual usage context.
- **S1.5** Media capture: camera integration, 60 s cap, compression in an isolate, thumbnail generation, persisted state machine, gallery view.
- **S1.6** **Export/import.** SQLite + media directory → zip → share sheet. Import with a version check. Non-negotiable per Section 1.5.
- **S1.7** Orphan sweep, storage budget, settings screen.

**Exit criteria:** 20+ real sessions logged. Export produces a zip that imports cleanly onto a wiped install. Storage growth is measured and matches projection.

### Phase 2 — Health Connect / wearable integration (Sprints 4–5)

- **S2.1** `HealthDataSource` interface + `HealthConnectSource` via the `health` package. Availability detection and Play Store install routing for Android < 14.
- **S2.2** Permission lifecycle: manifest declarations, rationale intent + activity-alias, background and history permissions, revocation-tolerant re-checking, graceful "reconnect" UI.
- **S2.3** Changes API integration with cursor persistence and expired-token fallback. Dedup via the unique index. Aggregation for daily totals; raw HR only within logged sessions.
- **S2.4** Background sync via `WorkManager`, backoff, `sync_cursors` failure tracking, staleness indicator in the UI.
- **S2.5** Zone derivation from raw HR + configurable max HR, with `zone_model_version` recompute path.
- **S2.6** Session matching: Health Connect `ExerciseSessionRecord` ↔ your logged sessions, with manual unlink.
- **S2.7** *Decision gate:* choose the iOS Fitbit path (Section 3.1) and, if (a), build `FitbitWebApiSource` here rather than in Phase 4 — it's also useful on Android for historical backfill. Begin the Play Console health declaration if publishing.

**Exit criteria:** a week of Fitbit data lands automatically with zero duplicates across repeated syncs, an app kill mid-sync, and a permission revoke/re-grant cycle.

### Phase 3 — Analytics, streaks, habit engine (Sprints 6–7)

- **S3.1** `habit_definitions` and the cadence evaluator. Explicit day-boundary rule, `grace_days`, timezone-travel correctness. **Heavy unit testing with an injected clock** — this is where the subtle bugs live.
- **S3.2** Streak computation, missed-session detection, `status='skipped'` backfill.
- **S3.3** Progression analytics: per-exercise volume and estimated-1RM trends, weekly consistency, HR-zone distribution over time.
- **S3.4** Home dashboard, per-exercise history, calendar heatmap.
- **S3.5** Local notifications for scheduled sessions and streak-at-risk warnings. Keep these sparse — a nagging app gets uninstalled.

**Exit criteria:** streak logic passes a test suite covering DST transitions, timezone travel, grace days, and retroactive edits. Analytics queries stay under 100 ms on a year of synthetic data.

### Phase 4 — Cloud sync, auth, remote backup (Sprints 8–10)

Only start this when a concrete trigger fires: a second device, a second user, or a genuine backup requirement that export doesn't satisfy.

- **S4.1** Supabase project, Postgres schema mirroring the local one, RLS policies, `server_rev` triggers.
- **S4.2** Auth + the local-data claim flow: sign-up, then `UPDATE ... SET user_id = <uid> WHERE user_id = 'local'`, guarded against double-claim.
- **S4.3** `SyncCoordinator`: pull-then-push, `(updated_at, id)` cursor, batching, backoff, partial-failure state machine. Remote data sources implemented here — and note that **no file in `domain/` or `presentation/` is touched in this sprint**. If one is, the seam was wrong; find out why before continuing.
- **S4.4** Conflict resolution: per-row LWW on `updated_at` with `device_id` tie-break, `sync_state='conflict'` for anything ambiguous, and a minimal conflict-review UI.
- **S4.5** Media upload: TUS/multipart with resume, presigned URLs, thumbnail-first policy, `WorkManager` constraints, backfill of the existing local corpus.
- **S4.6** Eviction of synced originals under the storage budget; remote-first resolution in the media viewer with local-cache fallback.
- **S4.7** Fresh-install restore path: sign in → pull → thumbnails → lazy original fetch.

**Exit criteria:** two devices converge to identical state after concurrent offline edits to the same session. A wiped install restores fully from remote. Domain and presentation layer diff for this phase is empty.

---

## 7. Open decisions and risks

| # | Item | Why it matters | Suggested resolution point |
|---|---|---|---|
| 1 | iOS Fitbit path (Web API / bridge app / no Fitbit) | Determines whether Phase 2 builds one integration or two | Decision gate S2.7 — but think about it now, because option (a) changes Phase 2 scope |
| 2 | Fitbit "Personal" app type and intraday access | Whether you get fine-grained HR without partner approval | Verify on the Fitbit developer portal before S2.7 |
| 3 | Play Store publishing vs sideload-only | Health apps declaration is a multi-day review with a privacy-policy prerequisite | Decide in Phase 2; if publishing, start the declaration immediately |
| 4 | Day-boundary rule for streaks | Every streak bug traces back to this | Phase 1, written down explicitly; suggest 04:00 local |
| 5 | Video encoding toolchain | `ffmpeg_kit_flutter` retirement makes this a live supply-chain risk | Verify current status in S1.5; default to platform-native encoders |
| 6 | `health` package single-maintainer risk | Your entire Phase 2 depends on it | Mitigated by the `HealthDataSource` wrapper; keep a platform-channel fallback in mind |
| 7 | Streak grace policy | Product decision that determines whether the mechanic survives real life | Phase 3; suggest one forgiven day per week |
| 8 | Whether a backend is ever needed | The Phase 4 trigger | Revisit after 3 months of real use, not before |

---

## Appendix — Summary of recommendations

| Decision | Recommendation |
|---|---|
| Architecture strategy | **A+**: local-first, sync-ready schema, export in Phase 1 |
| Local database | **Drift** (SQLite). Not Isar — abandoned upstream |
| State management | **Riverpod** with codegen |
| ID strategy | **Client-generated UUIDv7**, from the first commit |
| Deletion | **Tombstones only** |
| Read model | **Always local**, permanently, even post-sync |
| Health package | **`health`** ^13.3.x, wrapped behind your own interface |
| Android health source | Health Connect, Changes API, dedup on `Metadata.id` |
| iOS health source | **Fitbit Web API** (Fitbit → HealthKit does not exist) |
| Video | H.264 720p, **60-second hard cap** |
| Video toolchain | Platform-native encoders; verify `ffmpeg_kit` status first |
| Media paths | **Relative**, resolved at read time |
| Backend (if/when) | **Supabase**, not hand-rolled |
| Conflict resolution | Per-row LWW on `updated_at`, `device_id` tie-break |
