# Fitness & Habit Tracker — Locked Architecture Baseline

**Status:** LOCKED — input to High-Level Design
**Date:** 8 September 2026
**Supersedes:** nothing. Companion to `fitness-tracker-architecture.md`, which holds the full rationale.
**Change control:** items in Section 1 are frozen for the first cut. Changing one means revisiting the HLD.

---

## 0. First-cut scope statement

**App only. No backend, no cloud, no accounts.** Single user, single device, local-first, offline by default. Everything ships to the device.

Deferred to a later phase, in this order: push-only backup → bidirectional sync → multi-device.

The purpose of the first cut is a working habit loop in your hands. Anything that does not serve that is out of scope, however architecturally interesting.

---

## 1. Locked decisions

### 1.1 Strategy

| Decision | Locked value |
|---|---|
| Architecture strategy | **Local-first (A+)** — sync-ready schema from commit one, no backend in the first cut |
| Durability mechanism | **Manual export/import** — SQLite file + media directory → zip → share sheet. Ships in Phase 1, non-negotiable |
| Backend | **Deferred.** Not built, not stubbed, not scaffolded |
| First-cut platforms | **Android.** iOS builds from the same codebase but is not a release target |

### 1.2 Technology

| Concern | Locked choice | Note |
|---|---|---|
| Local database | **Drift (SQLite)** | Not Isar — abandoned upstream. Runs on a background isolate from day one |
| State management | **Riverpod** with `riverpod_generator` | `@riverpod` codegen, `AsyncNotifier`, `StreamProvider` over Drift `watch()` |
| ID strategy | **Client-generated UUIDv7** | Every synchronisable row. Never server-allocated |
| Timestamps | **UTC epoch milliseconds** | Plus `local_date` and `tz_offset_min` captured at write time |
| Deletion | **Tombstones only** (`deleted_at`) | No hard deletes anywhere |
| Time access | **Injected `Clock`** | `DateTime.now()` is banned outside the Clock implementation. Lint-enforced |
| Video codec | **H.264, 720p30, ~2.2 Mbps** | 60-second hard cap, enforced at capture |
| Video toolchain | **Platform-native encoders** (`MediaCodec` / `AVAssetExportSession`) | `ffmpeg_kit_flutter` is retired; do not depend on it |
| Image compression | `flutter_image_compress` | JPEG q80, longest edge 1920px |
| Media paths | **Relative to documents dir**, resolved at read time | Absolute paths break on iOS reinstall/restore |
| Background scheduling | `WorkManager` (Android) | iOS `BGTaskScheduler` when iOS becomes a target. Never assume it fires on time |

### 1.3 The structural rule

**The local database is permanently the read model. The network — whenever it arrives — is a background replicator that writes into it. The UI never awaits the network.**

This is what makes the eventual backend additive rather than a rewrite. It is not negotiable and it is the single most important line in this document.

Consequences, all enforced from the first commit:

- Repository interfaces expose `Stream<T>` reads backed by Drift, and local atomic writes. No `sync()`, `refresh()`, `fetch()` or `isOnline` on any repository.
- The `Failure` hierarchy is declared complete **now**, including `NetworkFailure`, `AuthFailure` and `ConflictFailure`, which are unreachable in the first cut. Dart 3 exhaustiveness then guarantees the UI already handles them.
- Reads paginate even though local reads need not.
- `user_id` is present on every synchronisable table, defaulted to `'local'`.
- `device_id` is threaded through every write.

### 1.4 Layering

```
presentation → domain ← data
```

`domain/` is pure Dart. Zero imports of `package:flutter`, `package:drift`, or any vendor SDK. Enforced by lint or CI check, not by discipline.

`data/remote/` **does not exist** in the first cut, and its absence is invisible from every other layer.

### 1.5 Health data architecture

**Three sources, one interface, built sequentially.**

| Source | Platform | Role | Phase |
|---|---|---|---|
| **Google Health API** (`health.googleapis.com/v4/`) | Both (cloud) | Primary. Fitbit + Google device data. Highest-fidelity intraday HR → real heart-rate zones | 2 |
| **Health Connect** | Android (on-device) | Budget/screenless wearables, Samsung Health, phone pedometer | 3+ |
| **HealthKit** | iOS (on-device) | Apple Watch | 3+ |

Locked design points:

- All three implement a single `HealthDataSource` interface.
- **The canonical metric model is ours, not any vendor's.** Units, timezone handling, sleep-stage taxonomy and session-type enums are normalised inside per-source mappers. Domain entities must be describable without reference to any vendor's documentation. This is the primary defence against the schema quietly becoming Google's schema.
- **`health_snapshots` holds one row per day per source**, not one row per day. A resolution step picks the winner per metric. Today it always picks the only row.
- **`source_priority(metric, source_id, rank)` is a table, not code.** Sensible defaults ship; per-metric override is exposed in the UI behind an advanced view. Primary UI is a single drag-to-reorder source list.
- Dedup is enforced by a **unique index on `(source_id, source_package, source_record_id)`**, not by application logic.
- Per-source quality signals (coverage, anomaly counts) are recorded so sources can be ranked on evidence.
- **Legacy Fitbit Web API is not to be used.** It is decommissioned in September 2026. Build only against the Google Health API.

### 1.6 Capability tiers

| Tier | Content | Dependency |
|---|---|---|
| **0 — always** | Attendance, session status, streaks, habit cadence | None. No permissions, no platform check, no health data — **ever**, including for enrichment |
| **1 — user action** | Exercise logs, sets/reps/weight, media, notes | User choice only |
| **2 — capability-gated** | All health enrichment | Platform + permission + source availability |

Tier 2 availability is queried from a single `CapabilityRegistry` returning per-metric status with a reason. Unavailable metrics render as an empty state explaining why — never a blank chart, never a silent zero.

**Onboarding must not gate first run on any permission dialog.** A workout can be logged before the app asks for anything.

### 1.7 Schema primitives

Every synchronisable table:

```sql
id          TEXT    NOT NULL PRIMARY KEY,   -- UUIDv7
user_id     TEXT    NOT NULL DEFAULT 'local',
created_at  INTEGER NOT NULL,               -- UTC epoch ms
updated_at  INTEGER NOT NULL,
deleted_at  INTEGER,                        -- tombstone
sync_state  INTEGER NOT NULL DEFAULT 0,     -- 0 pending, 1 syncing, 2 synced, 3 conflict
server_rev  INTEGER,
device_id   TEXT    NOT NULL
```

All reads filter `deleted_at IS NULL`. All writes bump `updated_at` and reset `sync_state`. Both enforced in a single base DAO so they cannot be forgotten.

Tables: `workout_sessions`, `exercise_logs`, `exercises`, `media_attachments`, `health_snapshots`, `sync_cursors`, `habit_definitions`, `source_priority`. Full DDL in `fitness-tracker-architecture.md` §4.

### 1.8 Product rules that are architectural

| Rule | Value | Why it's locked |
|---|---|---|
| Day boundary | **04:00 local** | Streak correctness depends on it; deriving it later from UTC is impossible after timezone travel |
| Streak grace | **One forgiven day per week** (`grace_days`) | A streak that breaks on one miss gets abandoned |
| Video length | **60 seconds, hard** | Eliminates most downstream storage and upload problems at source |
| Storage budget | **2 GB default**, visible in settings | Never evict silently while local-only — that is data loss |
| Thumbnails | **Never evicted** | ~15 KB each; keeps history browsable forever |
| Missed sessions | Explicit `status='skipped'` rows | Makes absence queryable rather than inferred |

---

## 2. Explicitly deferred

Not in the first cut. Listed so they are not silently reintroduced.

| Item | Trigger to revisit |
|---|---|
| Push-only backup (Supabase) | After the core loop works and is in daily use |
| Bidirectional sync + conflict resolution | A genuine second device |
| Auth / accounts | The backup phase |
| Media upload, presigned URLs, resumable transfer | The backup phase |
| Multi-user / tenancy | Other users, if ever |
| Health Connect source | After Google Health API has been in real use for a month |
| HealthKit source | When Apple Watch data is actually wanted |
| iOS release | After the Android app is in daily use |
| HEVC video | Only if the 60s cap is lifted |

Deferring sync also defers the conflict-resolution *product* question — what a conflict means — which cannot be answered well before a second device exists.

---

## 3. Open items requiring external verification

Blocking Phase 2, not Phase 1. Start on them early; two have external lead time.

| # | Item | Owner | Impact if unresolved |
|---|---|---|---|
| 1 | Fitbit account migrated to a Google Account | Mitesh | Legacy Fitbit accounts cannot access the Google Health API **at all** |
| 2 | Application type / approval needed for intraday heart rate under Google Cloud Console registration | Verify on `developers.google.com/health` | Heart-rate zones do not ship without it |
| 3 | Play Store publish vs sideload-only | Mitesh | Determines whether the Play Console health apps declaration (external review, days) is on the critical path when Health Connect lands. Sideload-only ⇒ not applicable |
| 4 | Current status of platform video-encoding approach | Verify at Phase 1 S1.5 | Fallback plan if native encoding proves awkward |
| 5 | `health` package relevance | Reassess | May not be needed at all if Google Health API is a direct REST integration |

---

## 4. First-cut phase plan

Sprints are notional two-week solo blocks. Exit criteria matter more than timeboxes.

### Phase 1 — Local foundation, UI shell, media capture

*Goal: logging real workouts by the end of sprint 2.*

1. Scaffold, layer-enforcement lint, Drift on background isolate, Riverpod codegen, `Clock` / `UuidV7` injectables
2. Full schema with §1.7 primitives; migration harness + round-trip migration test from version one
3. Domain entities, complete `Failure` hierarchy, repository interfaces, local data sources, mappers
4. Workout logging UI — the core loop. Must be usable one-handed with sweaty fingers
5. Media capture: camera, 60s cap, isolate compression, thumbnails, persisted state machine, gallery
6. **Export/import** — zip + share sheet, version-checked import
7. Orphan sweep, storage budget, settings

**Exit:** 20+ real sessions logged. Export imports cleanly onto a wiped install. Storage growth measured and matching projection.

### Phase 2 — Google Health API integration

`HealthDataSource` interface, `GoogleHealthApiSource`, Google OAuth 2.0 with PKCE as a public client, refresh token in `flutter_secure_storage`, `source_priority` seeded, dedup index live, background sync via `WorkManager`, capability registry wired, HR zone derivation with `zone_model_version`.

**Exit:** a week of data lands automatically with zero duplicates across repeated syncs, an app kill mid-sync, and a token revoke/re-grant cycle.

### Phase 3 — Analytics, streaks, habit engine

Cadence evaluator, streak computation with grace days, missed-session detection, progression analytics (volume, estimated 1RM, consistency, zone distribution), dashboard, calendar heatmap, sparse-data coverage handling, sparse local notifications.

**Exit:** streak logic passes tests covering DST transitions, timezone travel, grace days and retroactive edits. Analytics under 100 ms on a year of synthetic data.

### Later — additional sources, then backup, then sync

Health Connect, HealthKit, per-metric source UI. Then push-only backup. Then bidirectional sync when a second device exists.

---

## 5. Guardrails

Three failure modes this project is specifically exposed to, recorded so they can be checked against:

1. **Building the extensibility layer instead of the app.** The seams are: one interface, canonical model, per-source rows, priority table. That is the complete list. A source-negotiation framework for one source is the archetypal way a personal project dies interesting.
2. **Letting Tier 0 acquire a dependency.** The moment attendance or streaks read health data — even as enrichment — the core mechanic inherits every permission, platform and network failure mode the architecture was built to keep out of it.
3. **Building the backend against a moving schema.** The deferral in Section 2 is not conservatism; it is sequencing. Every entity change costs four files once a remote tier exists, and entity changes are weekly during Phase 1.

---

## 6. What HLD needs to cover

Not decided here; the HLD's job.

- Module and package decomposition, dependency graph
- Concrete Drift table definitions and DAO surfaces
- Provider graph and screen-level state ownership
- Navigation model and screen inventory
- `CapabilityRegistry` and `source_priority` resolution algorithm
- Media pipeline state machine and isolate topology
- `GoogleHealthApiSource` interaction design: auth flow, token lifecycle, pagination, backoff, cursor persistence
- Habit engine evaluation model and streak algorithm
- Test strategy — unit, golden, integration; fake data sources; clock control
- Error and empty-state catalogue per capability tier
