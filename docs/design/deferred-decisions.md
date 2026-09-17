# Deferred decisions

Known deviations from the locked design, recorded when found and deliberately
not acted on yet. Each entry says what is wrong, why it was left, and what the
fix costs. Delete an entry when it is resolved.

---

## D1 — The 04:00 day boundary lives in `Clock`

**Status:** open, deferred by choice
**Found:** 17 September 2026
**Files:** `lib/core/util/clock.dart`, `lib/presentation/today_screen.dart`

### What is wrong

`Clock` owns both time-telling and the product rule that a training day starts
at 04:00 (`dayBoundaryHour`, `localDateFor`, `today`).

**Single Responsibility Principle** — the module has two reasons to change, and
they belong to different actors: a developer changing the time source, and the
product owner changing where a day starts.

**Interface Segregation Principle** — no client uses the whole interface:

| Consumer | Uses | Ignores |
|---|---|---|
| `data/local/database.dart` | `nowUtcMillis`, `tzOffsetMinutes` | `localDateFor`, `today` |
| `presentation/today_screen.dart` | `today`, `localDateFor` | `nowUtcMillis` |

The two method groups have different clients, so one cut resolves both.

**Open/Closed**, marginally — the boundary is a top-level `const`, so it cannot
be varied by configuration or injection, not even in a test.

Not violated: DIP (consumers already depend on the abstraction) and LSP
(`FakeClock` substitutes cleanly).

### Why it is wrong here specifically

The locked design §1.8 files the day boundary under "product rules that are
architectural", and §1.4 puts such rules in `domain/` as pure Dart. The rule is
policy; `core/util/` is mechanism. The walking-skeleton spec baked the
conflation into the `Clock` interface it prescribed.

### Why it was left

The walking-skeleton spec forbids adding layers "on schedule" — they arrive
"when a file gets uncomfortable". The discomfort is now recorded; the fix waits
for a second consumer of the boundary, which streaks and grace days will supply.

### The fix, when taken

- New `lib/domain/time/day_boundary.dart`, pure Dart, no imports:
  `final class DayBoundary { const DayBoundary({this.hour = 4}); String localDateFor(DateTime moment); }`
  The boundary becomes a field, not a global const.
- `core/util/clock.dart` shrinks to `nowUtc`, `nowUtcMillis`, `tzOffsetMinutes`.
- `presentation/today_screen.dart` — add `dayBoundaryProvider`, update two call
  sites.
- `data/local/database.dart` — no change. It never used the boundary, which is
  the evidence the seam is in the right place.
- `test/unit/clock_test.dart` becomes `test/unit/day_boundary_test.dart`. Both
  cases get simpler: `localDateFor` becomes a pure function needing no fake.

Cost: one new file, ~25 lines moved, two call sites, one renamed test. No
behaviour change.

Side effect: `tool/check_layers.sh` has been passing vacuously on an empty
`lib/domain/` since the first commit. After this it guards real code.

### Update — 17 September 2026 (Slice 1.1)

Calendar backfill required recovering the UTC offset in force on a past date,
so `Clock` gained `dateTimeForLocalDate(String)`. That is a sixth method and a
second piece of calendar policy, so this entry got worse, not better: the
eventual `DayBoundary` extraction must take `dateTimeForLocalDate` with it,
since both it and `localDateFor` are inverses of the same 04:00 rule.

`data/local/database.dart` now calls `localDateFor`, `today` and
`dateTimeForLocalDate` for validation, so the claim that only the UI depended
on the boundary no longer holds. The ISP argument is unchanged — the two method
groups still have different clients — but the split is now a three-file change
rather than two.

### Open question

The name. `DayBoundary` in `domain/time/`, or something closer to the domain
such as `TrainingDay` or `AttendanceCalendar`. It will stick — streaks and
grace days both depend on it.
