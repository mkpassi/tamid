# Tamid

Personal fitness and habit tracker. Flutter, Android first.

Tamid (תמיד) means "always" — consistency over intensity.

## What it does today

One screen that answers a single question: **did I train today?**

- Yes / Not today, recorded against a local day that starts at 04:00
- A month calendar of past days, tap to answer, change or clear
- Backfill up to 30 days; older days and future days are not editable

## Design

The local database is permanently the read model. The UI watches a Drift
stream and never awaits a network — there is no backend, and adding one later
is meant to be additive rather than a rewrite.

Every row carries sync-ready primitives from the first commit: client-generated
UUIDv7 ids, UTC epoch milliseconds, `local_date` plus `tz_offset_min` captured
at write time, and tombstones instead of deletes.

- `docs/design/fitness-tracker-locked-design.md` — the authoritative baseline
- `docs/design/fitness-tracker-architecture.md` — rationale
- `docs/design/deferred-decisions.md` — known deviations, deliberately unfixed
- `CLAUDE.md` — the rules this codebase is held to

## Stack

Flutter via FVM · Drift (SQLite, background isolate) · Riverpod

## Running it

```sh
fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs
fvm flutter run
```

Use `fvm flutter`, not bare `flutter` — the SDK is pinned in `.fvmrc`, and
generated files (`*.g.dart`) are not committed, so codegen must run first.

## Checks

```sh
fvm flutter analyze
fvm flutter test
./tool/check_layers.sh   # lib/domain stays pure Dart
```
