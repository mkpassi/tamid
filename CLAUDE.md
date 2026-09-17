# Tamid

Personal fitness and habit tracker. Flutter, Android first.
Tamid (תמיד) means "always" — consistency over intensity.

## Before writing any code
Read `docs/design/fitness-tracker-locked-design.md`. It is the authoritative
baseline. `fitness-tracker-architecture.md` holds rationale only; where the
two disagree, the locked design wins.

## Non-negotiable rules
- `lib/domain/` is pure Dart. No Flutter, Drift, Riverpod or vendor imports.
- The local DB is the permanent read model. The UI never awaits the network.
- All IDs are client-generated UUIDv7. Deletes are tombstones (`deleted_at`).
- `DateTime.now()` is banned outside `core/util/clock.dart`.
- Repositories expose streams + local atomic writes. No sync()/fetch()/isOnline.
- Tier 0 (attendance, streaks) must never read health data.
- Media paths are stored relative, never absolute.
- No backend, no auth, no `data/remote/` in the first cut.

## Environment
- Flutter via FVM. minSdk 26, targetSdk 36 (edge-to-edge is enforced).
- Codegen: `fvm dart run build_runner watch --delete-conflicting-outputs`

## Workflow
Plan first. Produce a plan, wait for review, then implement.
