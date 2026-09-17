# Fitness & Habit Tracker — Design Artifact Set

**Project:** Personal cross-platform fitness and habit tracker (Flutter)
**Phase:** Design locked, HLD pending
**Date:** 8 September 2026

---

## Reading order

Start at **00** (this file) → **02** for the locked decisions → **03** for the diagrams. Go to **01** only when you need to know *why* a decision was made.

| # | Artifact | Purpose | Status |
|---|---|---|---|
| 01 | `fitness-tracker-architecture.md` | Full analysis: Strategy A vs B trade-off matrix, migration friction accounting, Dart contracts, complete SQL schemas (SQLite + Postgres), media pipeline, phased roadmap | Reference — read for rationale |
| 02 | `fitness-tracker-locked-design.md` | **The working document.** Frozen decisions, deferred items, open verification items, first-cut phase plan, guardrails, HLD scope | **Authoritative** |
| 03 | `01-hld-component.puml` | Component architecture — layers, dependency directions, deferred `remote` package | Diagram |
| 04 | `02-seq-log-workout.puml` | Core loop — local write, reactive read | Diagram |
| 05 | `03-seq-media-capture.puml` | Capture → compress (isolate) → thumbnail, with crash recovery | Diagram |
| 06 | `04-seq-health-sync.puml` | Background health ingestion, dedup, per-metric source resolution | Diagram |
| 07 | `05-seq-capability-resolution.puml` | Capability tiers, permission lifecycle, source configuration | Diagram |
| 08 | `06-state-and-datamodel.puml` | Media state machine + entity relationships (**two `@startuml` blocks — renders as two images**) | Diagram |

Where 01 and 02 disagree, **02 wins** — the locked baseline reflects decisions taken after the analysis document was written (notably: no backend in the first cut, three health sources rather than two, and Google Health API replacing the decommissioned Fitbit Web API).

---

## Rendering the diagrams

```bash
# All at once
plantuml -tsvg *.puml

# Single file
plantuml -tpng 01-hld-component.puml

# VS Code: PlantUML extension, Alt+D to preview
```

Note that `06-state-and-datamodel.puml` contains two diagram blocks and will produce two output files.

---

## The three things that carry the design

**1. The local database is permanently the read model.**
The network — whenever it arrives — is a background replicator that writes into Drift. The UI never awaits it. This is what makes the eventual backend additive rather than a rewrite, and it is visible in diagram 03 as the arrow direction into Drift.

**2. Attendance depends on nothing.**
Tier 0 (attendance, streaks, habit cadence) must keep working with every integration disabled, every permission denied, and no network. It never reads health data, not even for enrichment. Diagram 07 shows Tier 0 rendering before any capability is queried.

**3. The canonical metric model is ours, not any vendor's.**
All vendor units, timezone handling, sleep taxonomies and session enums are normalised inside per-source mappers. Domain entities must be describable without reference to any vendor's documentation. This is the primary defence against the schema quietly becoming Google's schema.

---

## Locked stack

| Concern | Choice |
|---|---|
| Strategy | Local-first (A+), sync-ready schema, no backend in first cut |
| Local DB | Drift (SQLite), background isolate |
| State | Riverpod + `riverpod_generator` |
| IDs | Client-generated UUIDv7 |
| Deletes | Tombstones only |
| Time | Injected `Clock`; `DateTime.now()` banned |
| Health sources | Google Health API → Health Connect → HealthKit (sequential) |
| Video | H.264 720p30, 60s hard cap, platform-native encoders |
| Media paths | Relative, resolved at read time |
| Day boundary | 04:00 local |
| Streak grace | One forgiven day per week |

---

## Blocking items before Phase 2

| # | Item | Why it matters |
|---|---|---|
| 1 | Fitbit account migrated to a Google Account | Legacy Fitbit accounts cannot reach the Google Health API at all |
| 2 | Application type / approval for intraday heart rate | Heart-rate zones do not ship without it |
| 3 | Play Store publish vs sideload-only | Determines whether the health apps declaration (external review) is on the critical path |

Neither 1 nor 2 blocks Phase 1, but both have external lead time — start now.

---

## Not yet drawn

- Export/import flow (Phase 1 deliverable, should be added before the HLD is final)
- Habit engine evaluation / streak algorithm detail
- Navigation model and screen inventory

---

## Next

High-Level Design. Scope is set out in §6 of the locked baseline: module decomposition, Drift table definitions and DAO surfaces, provider graph, navigation model, `CapabilityRegistry` and resolution algorithm, media isolate topology, Google Health API interaction design, habit engine model, test strategy, and the error/empty-state catalogue per tier.
