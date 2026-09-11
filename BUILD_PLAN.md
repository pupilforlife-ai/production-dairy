# Vejoy Production Management System — Build Plan

**Document:** `BUILD_PLAN.md`  
**Version:** 1.0  
**Stack:** Existing Node.js + Supabase + GitHub project  
**Execution model:** Incremental delivery with Codex in VS Code  
**Planning target:** ~14–18 weeks for strong Phase 1, with factory-use MVP earlier

---

## 1. How Codex Should Use This Plan

Before starting any task:

1. Read `PRODUCT_SPEC.md`.
2. Read `TECHNICAL_SPEC.md`.
3. Read the current phase in this file.
4. Inspect the existing repo before changing architecture.
5. Do not replace an existing framework/configuration without explicit instruction.
6. Implement one coherent card/feature at a time.
7. Commit schema migrations and code together where practical.
8. Add tests as each business rule is implemented.
9. Mark unresolved assumptions in code comments/TODO docs rather than invent factory rules.
10. Do not expose confidential recipe data beyond authorized roles.

---

## 2. Delivery Philosophy

Do not build the whole system before factory use.

Target progression:

### Milestone A — Technical Foundation

Authentication, roles, master data, migrations, audit foundation.

### Milestone B — Digital Production Board MVP

Milk lot, shift, round, production board, paneer output/status.

### Milestone C — Operational Production

Intermediate stock, cutting, packing, FIFO, finished stock, handover.

### Milestone D — Factory Controls

Ingredients, packaging, waste, cold chain, utilities.

### Milestone E — Management Layer

Reconciliation, yield, costing, dashboards.

### Milestone F — Stabilisation

Real factory testing, corrections, training, data cleanup.

---

# PHASE 0 — Repository and Architecture Baseline

**Estimate:** 1–2 days

## Objectives

Understand the existing Node.js/Supabase project and establish project conventions.

## Tasks

### 0.1 Inspect repository

Codex should identify:

- package manager
- web framework
- folder structure
- current Supabase setup
- environment handling
- auth status
- test framework
- lint/format rules
- deployment workflow

### 0.2 Add specification files

Add:

- `PRODUCT_SPEC.md`
- `TECHNICAL_SPEC.md`
- `BUILD_PLAN.md`

### 0.3 Establish app conventions

Document:

- naming
- database migration workflow
- component structure
- API/service structure
- test commands

### 0.4 Add CI baseline if missing

At minimum:

- install
- lint
- typecheck if applicable
- test
- build

## Acceptance Criteria

- Existing project builds successfully.
- Specs are committed.
- Supabase connection works locally.
- Migration workflow is documented.
- GitHub branch/PR workflow is known.

---

# PHASE 1 — Authentication, Roles, Audit Foundation

**Estimate:** Week 1

## Epic 01 — Authentication & Security

### 1.1 Supabase Auth integration

Implement login/logout/session handling.

### 1.2 Profiles and roles

Create:

- `profiles`
- initial roles:
  - `production_manager`
  - `owner`

### 1.3 Route/page protection

Unauthorized users cannot access application pages.

### 1.4 Role helpers

Implement reusable role checks.

### 1.5 RLS baseline

Enable RLS and initial policies.

### 1.6 Audit event foundation

Create `audit_events`.

### 1.7 Lock/correction foundation

Create generic pattern needed for owner-only corrections.

## Acceptance Criteria

- Production manager can log in.
- Owner can log in.
- Role is available in server-side authorization.
- Production manager cannot perform an owner-only test operation.
- Owner can.
- Audit event can be written from a secure operation.
- Protected pages reject anonymous access.

---

# PHASE 2 — Master Data

**Estimate:** Week 1–2

## Epic 02 — Master Data & Recipes

### 2.1 Units of measure

Seed:

- L
- mL
- kg
- g
- piece
- packet
- case
- bucket

### 2.2 Storage locations

Seed Vejoy locations.

### 2.3 Temperature profiles

Seed:

- Chiller 3–5°C
- Freezer profile

### 2.4 Product families

Create product families.

### 2.5 Products / intermediate materials

Create Product Master supporting raw/intermediate/finished classification.

### 2.6 SKU Master

Implement known paneer, butter, ghee, and popper SKU data.

### 2.7 Packaging configurations

Support:

- fixed cases
- loose packets
- variable case configuration flag

### 2.8 Waste reasons

Create configurable waste reason master.

### 2.9 Supplier master

Minimal supplier records.

## Acceptance Criteria

- Owner can configure master data.
- Production manager can read operational master data.
- Products are not hard-coded in UI.
- A SKU can define pieces/packet and packets/case.
- Variable case configuration can be represented.
- Historical referenced master records cannot be casually deleted.

---

# PHASE 3 — Recipe Management

**Estimate:** Week 2

### 3.1 Recipe tables

Create recipe/version/component schema.

### 3.2 Recipe scaling service

Input:

- recipe version
- requested batch basis

Output:

- scaled theoretical component quantities

### 3.3 Recipe version lifecycle

New version must not overwrite old version.

### 3.4 Confidential access

Restrict sensitive recipe details.

### 3.5 Seed only confirmed recipes

Examples that may be seeded if desired:

- Ghee formula
- Blended butter formula
- JP filling formula
- Known halloumi recipe details explicitly provided

Do not invent missing ingredients.

## Acceptance Criteria

- Recipe can scale from base quantity to another batch size.
- Historical batch can retain old recipe version.
- Unauthorized role cannot edit restricted recipe.
- No formula is hard-coded in frontend components.

---

# PHASE 4 — Milk Receiving & Source Lots

**Estimate:** Week 2–3

## Epic 03

### 4.1 Source lot schema

Create milk and cream source lot support.

### 4.2 Milk Receiving screen

Fields:

- receipt date/time
- supplier
- lot/batch code
- litres received
- accepted/rejected
- notes

### 4.3 Milk allocation

Optional/available allocation to:

- Silo
- BMC 1
- BMC 2
- Holding Tank
- IBC Storage
- Direct Production

### 4.4 Milk lot detail

Show:

- received
- allocated
- consumed
- rejected/spilled
- remaining

### 4.5 Purchased cream receipt

Support one cream receipt = one source lot.

### 4.6 Cream lot merge capability

Design genealogy so a butter batch can consume multiple source cream lots.

## Acceptance Criteria

- Production manager can create Sunday milk lot.
- Lot code can be entered manually.
- Quantities are in litres.
- Milk lot remains available as parent source for production rounds.
- Remaining quantity cannot go below zero through normal consumption.
- Source lot history is audited.

---

# PHASE 5 — Shifts and Production Rounds

**Estimate:** Week 3–4

## Epic 04 / Epic 05 foundation

### 5.1 Production shift schema

Support explicit shift number.

### 5.2 Team member capture

Allow staff names even if not app users.

### 5.3 Production round creation

Fields:

- source milk lot
- shift
- round number
- product/type
- recipe version
- planned/actual primary input
- start time
- status

### 5.4 Current human-readable batch identity

Display:

`Milk Lot / Shift / Round / Type`

### 5.5 Paneer codes

Support familiar:

- D
- C/S

### 5.6 Round output

Record gross output weight.

## Acceptance Criteria

- A 500 L paneer round can be recorded separately from another round under same milk lot.
- Shift 4 Round 3 D is uniquely identifiable.
- Batch size is configurable, not hard-coded to 500 L.
- Production manager can record team and output.
- Completed rounds can be locked.

---

# PHASE 6 — Digital Production Board MVP

**Estimate:** Week 4–5

## Epic 04

### 6.1 Board view

Rows represent production rounds.

### 6.2 Board fields

Display:

- shift
- round
- milk lot
- type
- status
- team
- cut by
- cutting
- produced quantity
- intermediate balance
- packing status

### 6.3 Filters

At minimum:

- current milk lot
- current week
- status
- product type

### 6.4 Status updates

Allow quick controlled updates for open rounds.

### 6.5 Responsive layout

Must work on factory desktop/tablet/phone browser.

## Acceptance Criteria

- Current whiteboard can be represented digitally.
- Production manager can create and update a round without navigating through many screens.
- D and C/S terminology is visible.
- Board can be used as the primary operational overview.

## Milestone

**MVP demo: Digital Production Board operational.**

---

# PHASE 7 — Intermediate Stock & Cutting

**Estimate:** Week 5–7

## Epic 05 / Epic 06

### 7.1 Intermediate lots

Create intermediate stock from production output.

### 7.2 Cutting transaction

Record:

- source batch
- source weight
- cut by
- cut type
- output quantities
- PAN111
- loss

### 7.3 Paneer workflow rule

Enforce:

Press → Cut → Freeze → Pack

Do not allow normal paneer to skip cutting before frozen-ready status.

### 7.4 Fresh-pack exception

Support MPAN010 / RPAN010.

### 7.5 PAN111

Create intermediate stock, not waste.

### 7.6 Recovered cream

Record recovered cream as co-product/intermediate.

### 7.7 Location transfer

Move cut stock into freezer/chiller.

## Acceptance Criteria

- 72 kg paneer can be allocated into several cut outcomes.
- PAN111 remains traceable to source paneer batch.
- Waste is separate from PAN111.
- Intermediate balance updates transactionally.
- Product can be located by cold room.
- Frozen stock can be traced back to production round.

---

# PHASE 8 — Packing & FIFO

**Estimate:** Week 7–8

## Epic 07

### 8.1 Packing run creation

Select SKU.

### 8.2 FIFO suggestion

Show oldest eligible intermediate stock first.

### 8.3 FIFO override

Warn but allow newer batch selection.

### 8.4 Multiple source lots

Allow packing from two or more batches if mixing occurred.

### 8.5 Cases and loose packets

Record both.

### 8.6 Packaging consumption

Record actual packaging used.

### 8.7 Finished stock creation

Generate finished stock movement.

### 8.8 Partial packing

Keep source intermediate balance when not fully consumed.

## Acceptance Criteria

- 37 cases + 6 loose SPP packets can be recorded.
- System calculates packet equivalent from case configuration.
- Oldest batch is recommended.
- Multiple source batches can feed one packing run.
- Finished stock quantity cannot exceed consumed material rules without explicit variance handling.

## Milestone

**Factory-use MVP: production + cutting + frozen stock + packing.**

---

# PHASE 9 — Ingredient and Packaging Inventory

**Estimate:** Week 8–10

## Epic 08

### 9.1 Ingredient receiving-in-scope boundary

Track material from the point production receives it.

### 9.2 Bulk Store

Record stock in shipping-container store.

### 9.3 Intermediate Store

Transfer stock for weekly/shift use.

### 9.4 Production consumption

Consume ingredients across batches.

### 9.5 Packaging inventory

Track printed packaging, boxes, polybags, vacuum bags, etc.

### 9.6 Stocktake adjustment flow

Owner-only or future approval rules.

### 9.7 Inventory report

Stock by location.

## Acceptance Criteria

- Material can transfer Bulk → Intermediate.
- Staff consumption does not require owner approval every time.
- Production manager can reconcile intermediate store.
- Packaging can be consumed against packing.
- Direct stock balance editing is blocked.

---

# PHASE 10 — Product-Specific Transformations

**Estimate:** Week 9–11

### 10.1 Halloumi workflow

Support:

- milk input
- halloumi output
- chiller
- vacuum halloumi
- cut halloumi
- halloumi popper input

### 10.2 SPP workflow

Support:

- cut paneer
- coating
- freezing
- flash frying
- refreezing
- packing

### 10.3 JP workflow

Support:

- PAN111
- cream-cheese filling batch
- fill jalapeños
- freeze
- crumb
- freeze
- flash fry
- freeze
- pack

### 10.4 Butter workflow

Support:

- internal/purchased cream
- pure butter
- split outputs
- blended batch

### 10.5 Ghee workflow

Support standard formula and yield.

## Acceptance Criteria

- Genealogy works through multiple internal transformations.
- PAN111 → cream-cheese filling → JP is traceable.
- Purchased cream → pure butter → BB05/PSBBB/PUBBB is traceable.
- Internal cream → butter → ghee is traceable.
- Multiple cream source lots can feed one butter batch.

---

# PHASE 11 — Waste & Yield

**Estimate:** Week 10–12

## Epic 09

### 11.1 Waste entry

Create waste event screen.

### 11.2 Waste reason configuration

Use seeded reasons.

### 11.3 Batch yield

Calculate actual.

### 11.4 Standard yield

Compare against configured target.

### 11.5 Litres/kg

Calculate paneer/halloumi operational metric.

### 11.6 Conversion yield

Butter/ghee and value-added transformations.

### 11.7 Unexplained variance

Identify quantity not represented by output, waste, recovery, or remaining stock.

## Acceptance Criteria

- Recoverable PAN111 is not counted as waste.
- Waste can be reported by reason/product/week.
- Batch yield can be compared with standard.
- Ghee 105 kg formula can show expected ~73.5 kg versus actual.
- Unexplained variance is visible rather than silently absorbed.

---

# PHASE 12 — Cold Chain

**Estimate:** Week 11–12

## Epic 10

### 12.1 Temperature entry

Manual entry by location.

### 12.2 Range validation

Flag out-of-range.

### 12.3 Chiller

3–5°C.

### 12.4 Freezer

Configured -18°C target profile.

### 12.5 Stock by cold room

Show quantities by location.

## Acceptance Criteria

- Staff can capture 4–6 readings/day.
- Out-of-range readings are clearly flagged.
- No advanced excursion workflow required.
- Management can view current stock by cold room.

---

# PHASE 13 — Utilities

**Estimate:** Week 12

## Epic 11

### 13.1 Diesel log

### 13.2 Paraffin log

### 13.3 Gas log

### 13.4 Electricity meter/consumption

### 13.5 Weekly utility report

### 13.6 Cost input

## Acceptance Criteria

- Weekly Friday utility entries can be captured.
- Electricity supports meter-start/meter-end if desired.
- Utility costs can feed costing.
- System marks these as factory/period measurements, not direct batch measurements.

---

# PHASE 14 — Distribution Handover

**Estimate:** Week 12–13

## Epic 13

### 14.1 Handover draft

Select finished stock.

### 14.2 Handover lines

Cases + loose units.

### 14.3 Confirmation

Record recipient/confirmation.

### 14.4 Stock decrement

Only on defined confirmation event.

### 14.5 Returns

Record damaged/rejected returns.

## Acceptance Criteria

- Production can create handover.
- Cannot hand over more than available.
- Confirmed handover leaves production stock.
- Distribution workflow after handover is out of scope.
- Returned rejected/damaged goods are not automatically saleable.

---

# PHASE 15 — Reconciliation

**Estimate:** Week 13–14

## Epic 09 / Reconciliation

### 15.1 Batch reconciliation

### 15.2 Intermediate reconciliation

### 15.3 Packing reconciliation

### 15.4 Weekly Sunday milk-lot reconciliation

### 15.5 Cream/butter/ghee reconciliation

## Weekly Milk Report

Show:

- received
- processed
- remaining
- rejected
- spilled
- accounted other
- unexplained difference

And production outputs:

- paneer
- halloumi
- cream
- other relevant outputs

## Acceptance Criteria

- Management can close/review a week's milk lot.
- Variance is automatically calculated.
- Results come from underlying transactions.
- Manual correction requires owner flow.

---

# PHASE 16 — Costing

**Estimate:** Week 14–16

## Epic 12

### 16.1 Material prices

Record effective costs.

### 16.2 Standard recipe cost

Calculate theoretical.

### 16.3 Actual batch input cost

Calculate actual.

### 16.4 Packaging cost

Per packing run/SKU.

### 16.5 Utility allocation

Implement first approved allocation method.

### 16.6 Cost/kg

Intermediate and finished.

### 16.7 Cost/packet

### 16.8 Cost/case

### 16.9 Standard vs actual variance

### 16.10 Co-product policy placeholder

Do not invent unapproved allocation.

## Acceptance Criteria

- Standard and actual cost can be compared.
- Cost sources are traceable.
- Allocated utility cost is identified as allocation.
- Actual cost is not calculated from guessed missing data.
- Co-product cost method remains configurable/future-ready.

---

# PHASE 17 — Dashboards & Reports

**Estimate:** Week 15–16

## Epic 14

### Owner Dashboard

Prioritize:

- losses
- yield
- wastage
- fuel
- electricity
- cold chain
- production output
- stock awaiting handover
- standard vs actual cost

### Production Manager Dashboard

Prioritize:

- active rounds
- batches awaiting cutting
- frozen stock awaiting packing
- FIFO warnings
- stock shortages
- incomplete reconciliations
- temperature logging status

## Acceptance Criteria

- Dashboards link to underlying transactions.
- Avoid decorative metrics with no operational use.
- Every metric has defined calculation logic.

---

# PHASE 18 — Audit, Locking, Owner Corrections

**Estimate:** Week 16

## Epic 15

### 18.1 Completed record locking

### 18.2 Owner correction UI

### 18.3 Correction reasons

### 18.4 Audit history viewer

### 18.5 Cancellation/void workflow

## Acceptance Criteria

- Production manager cannot silently edit completed record.
- Owner can post correction with reason.
- Original value remains visible in history.
- Audit report shows who/what/when.

---

# PHASE 19 — Factory Validation

**Estimate:** Week 16–18+

This phase is mandatory.

### 19.1 Shadow the whiteboard

For several shifts, run digital board alongside current board.

### 19.2 Compare records

Check:

- rounds
- output
- cutting
- frozen stock
- packing
- handover

### 19.3 Test Sunday milk cycle

Run a complete weekly lot.

### 19.4 Identify process friction

Record:

- fields staff skip
- unnecessary clicks
- unclear terminology
- timing issues
- mobile/tablet usability

### 19.5 Fix high-priority issues

### 19.6 Training

Train production manager and owners.

### 19.7 Go-live criteria

Agree before replacing current board entirely.

---

# 20. Suggested Release Milestones

## Release 0.1 — Foundation

Includes:

- auth
- roles
- master data
- source lots

## Release 0.2 — Digital Board MVP

Includes:

- shifts
- rounds
- paneer production board
- output/status

Target around Week 4–6.

## Release 0.3 — Factory Production MVP

Includes:

- cutting
- intermediate stock
- FIFO
- packing
- finished stock

Target around Week 7–9.

## Release 0.4 — Controls

Includes:

- ingredient inventory
- packaging
- waste
- cold chain
- utilities
- handover

Target around Week 10–13.

## Release 1.0 — Strong Phase 1

Includes:

- reconciliation
- costing
- dashboards
- audit corrections
- factory validation

Target around Week 14–18.

---

# 21. Codex Task Template

For every implementation task, use this format.

## Goal

What business outcome is being implemented?

## Relevant Specification

Reference exact section(s) in:

- `PRODUCT_SPEC.md`
- `TECHNICAL_SPEC.md`

## Existing Code to Inspect

List relevant files discovered before editing.

## Database Changes

- migration
- indexes
- RLS
- seed changes

## Backend / Service Changes

Describe transaction logic.

## UI Changes

Describe screen/interaction.

## Business Rules

List explicit rules.

## Tests

- unit
- integration
- E2E where needed

## Acceptance Criteria

Use binary/testable statements.

## Out of Scope

Prevent Codex from expanding scope.

---

# 22. First Codex Prompt

Recommended first prompt after placing these files in the repository:

> Read PRODUCT_SPEC.md, TECHNICAL_SPEC.md, and BUILD_PLAN.md in full. Inspect the existing repository and Supabase configuration without changing code yet. Report the current architecture, framework, folder structure, auth status, database/migration status, test setup, and any conflicts between the existing project and the technical specification. Then propose the smallest set of changes required to complete Phase 0. Do not implement anything until the assessment is complete.

After review:

> Implement Phase 0 only. Keep the existing framework and architecture unless there is a documented blocker. Add or update repository conventions, verify the Supabase migration workflow, ensure lint/typecheck/test/build commands work, and report all changed files.

Then:

> Implement Phase 1 — Authentication, Roles, Audit Foundation according to BUILD_PLAN.md. Before coding, summarize the schema migrations, RLS policies, service changes, UI changes, and tests you will add. Then implement the approved scope only.

---

# 23. Rules for Keeping the Specs Current

Whenever a business decision changes:

1. Update `PRODUCT_SPEC.md` first.
2. Update `TECHNICAL_SPEC.md` if architecture/data rules change.
3. Update `BUILD_PLAN.md` if sequencing/scope changes.
4. Commit the spec change with the implementation or before it.
5. Never allow code comments to become the only record of a business rule.

These three files are the project source of truth.
