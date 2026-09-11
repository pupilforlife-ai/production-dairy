# Vejoy Production Management System — Technical Specification

**Document:** `TECHNICAL_SPEC.md`  
**Version:** 1.0  
**Target stack:** Node.js + Supabase + GitHub  
**Database:** Supabase PostgreSQL  
**Authentication:** Supabase Auth  
**Storage:** Supabase Storage where needed  
**Target:** Responsive internal web application

---

## 1. Architecture Goals

The system must prioritize:

- Correct production genealogy
- Transactional stock integrity
- Auditability
- Configurable master data
- Role-based security
- Incremental implementation
- Responsive web use on desktop/tablet/phone
- Simple deployment and maintenance

Avoid premature microservices.

Use a modular monolith or single application/backend boundary for Phase 1.

---

## 2. Suggested Application Architecture

```text
Web Client
   |
   v
Node.js Application / API Layer
   |
   +---- Supabase Auth
   |
   +---- Supabase PostgreSQL
   |
   +---- Supabase Storage (optional files/docs later)
```

The project may use a Node.js web framework already chosen in the repo. If none is chosen, Codex should not replace the existing scaffold without explicit approval.

---

## 3. Source-of-Truth Files

The repository should contain:

- `PRODUCT_SPEC.md`
- `TECHNICAL_SPEC.md`
- `BUILD_PLAN.md`

Codex should read these before beginning a new implementation phase.

Business rules in `PRODUCT_SPEC.md` take precedence over guessed implementation shortcuts.

---

## 4. Domain Modules

Recommended modules:

1. Auth & Users
2. Master Data
3. Recipe Management
4. Milk / Cream Receiving
5. Production Planning
6. Digital Production Board
7. Production Batches / Transformations
8. Inventory & Stock Movements
9. Cutting
10. Packing
11. Waste & Recovery
12. Cold Chain
13. Utilities
14. Costing
15. Distribution Handover
16. Reconciliation
17. Dashboards / Reporting
18. Audit & Corrections

---

## 5. Core Data Model

Use UUID primary keys unless the existing project has a different established standard.

All mutable business tables should normally include:

- `id uuid primary key`
- `created_at timestamptz`
- `created_by uuid`
- `updated_at timestamptz`
- `updated_by uuid`
- `status`
- optional `locked_at`
- optional `locked_by`

Do not use display codes as primary keys.

---

## 6. Users and Roles

### `profiles`

Suggested fields:

- `id uuid` → references `auth.users.id`
- `display_name`
- `role`
- `active`
- timestamps

Initial role enum or lookup:

- `production_manager`
- `owner`

Prefer a role/permission table if the existing application expects future role expansion.

### Authorization principle

UI checks are for usability only.

Sensitive authorization must be enforced in database RLS and/or server-side application logic.

---

## 7. Supabase RLS

RLS should be enabled for business tables exposed through Supabase APIs.

Recommended policy pattern:

### Production Manager

Can:

- select operational data
- insert operational transactions
- update records that are still open/unlocked

Cannot:

- delete audited production records
- edit locked records
- perform owner corrections
- modify owner-only administration

### Owner

Can:

- read all records
- perform allowed master-data maintenance
- create correction/adjustment transactions
- manage roles/admin data as configured

Avoid policies that allow unrestricted `update` on historical records.

Use server-side functions/RPC for sensitive operations if easier to secure transactionally.

---

## 8. Audit Model

### `audit_events`

Suggested fields:

- `id`
- `entity_type`
- `entity_id`
- `action`
- `actor_user_id`
- `occurred_at`
- `old_data jsonb`
- `new_data jsonb`
- `reason`
- `request_id` optional

Audit should be generated automatically where practical.

Use:

- database triggers for generic change history, and/or
- explicit service-level audit events for business transactions.

Critical operations must not depend only on frontend logging.

---

## 9. Correction Model

Do not overwrite locked/completed transaction history.

Recommended pattern:

### `corrections`

- `id`
- `entity_type`
- `entity_id`
- `field_or_measure`
- `adjustment_value` and/or `replacement_value`
- `reason`
- `created_by`
- `created_at`

Alternative: entity-specific adjustment tables where accounting-style deltas are needed.

Rules:

- owner-only
- original record preserved
- derived totals include correction
- audit event created
- UI clearly shows corrected value and history

---

## 10. Master Data Tables

Suggested tables:

### `product_families`

- name
- code
- active

### `products`

- family_id
- code
- name
- product_type (`raw`, `intermediate`, `finished`)
- weight_mode (`fixed`, `variable`)
- storage_profile_id
- active

### `skus`

- product_id
- code
- description
- unit_weight_g nullable
- pieces_per_packet nullable
- active

### `packaging_configs`

- sku_id
- units_per_inner_pack nullable
- packets_per_case nullable
- nominal_case_weight_kg nullable
- variable_case_allowed boolean
- effective_from
- effective_to

### `units_of_measure`

- code
- name
- dimension

### `storage_locations`

- code
- name
- location_type
- temperature_profile_id nullable
- active

### `temperature_profiles`

- name
- min_c
- max_c

---

## 11. Recipe Tables

### `recipes`

- id
- product_id
- name
- confidential boolean
- active

### `recipe_versions`

- recipe_id
- version_number
- basis_quantity
- basis_uom
- effective_from
- effective_to
- status
- created_by

### `recipe_components`

- recipe_version_id
- material_product_id / ingredient_id
- quantity
- uom
- tolerance_min nullable
- tolerance_max nullable
- sequence nullable

A production batch must reference `recipe_version_id`.

Never update an old recipe version to represent a new formula.

---

## 12. Material / Ingredient Master

A unified `materials` model may be preferable to separate product/ingredient tables if designed cleanly.

If separate:

### `ingredients`

- code
- name
- default_uom
- confidential_name_alias nullable
- active

### `packaging_materials`

- code
- name
- default_uom
- sku association where relevant
- active

Keep implementation consistent. Do not create duplicate master entities that represent the same physical material.

---

## 13. Source Lots

### `source_lots`

Supports milk, purchased cream, and later other received materials.

Fields:

- `lot_type`
- `lot_code`
- `received_at`
- `supplier_id nullable`
- `received_quantity`
- `uom`
- `status`
- `notes`

### `source_lot_allocations`

Optional vessel/location allocation:

- source_lot_id
- storage_location_id
- quantity
- uom
- movement_reference

---

## 14. Suppliers

### `suppliers`

Phase 1 minimal fields:

- name
- supplier_type
- active

Raw milk may currently be from one supplier, but do not hard-code one supplier.

---

## 15. Production Shifts

### `production_shifts`

- milk/source lot reference if applicable
- shift_number
- started_at
- ended_at nullable
- team_notes
- status

### `shift_members`

- shift_id
- person_name or user reference
- role/notes optional

Staff may not all be application users initially, so allow production-team names separate from authenticated users.

---

## 16. Production Rounds / Batches

### `production_batches`

Fields:

- `batch_code` manual/display code
- `parent_source_lot_id`
- `shift_id`
- `round_number`
- `product_id`
- `recipe_version_id`
- `planned_input_quantity`
- `actual_primary_input_quantity`
- `input_uom`
- `gross_output_quantity`
- `output_uom`
- `status`
- `started_at`
- `completed_at`
- `locked_at`
- `notes`

Do not assume all batches use 500 L.

---

## 17. Batch Inputs

### `production_batch_inputs`

Allows multiple materials/lots per batch.

Fields:

- batch_id
- material/product_id
- source_lot_id nullable
- source_intermediate_lot_id nullable
- quantity
- uom
- standard_quantity nullable
- variance_quantity nullable

Supports:

- milk
- ingredients
- purchased cream
- pure butter
- PAN111
- AF oil
- packaging later if desired

---

## 18. Batch Outputs

### `production_batch_outputs`

Fields:

- batch_id
- product_id
- quantity
- uom
- output_type (`primary`, `coproduct`, `recovered`, `waste_candidate`)
- destination_location_id
- generated_intermediate_lot_id nullable

This allows one process to produce:

- paneer
- recovered cream
- PAN111
- waste
- pure butter
- ghee

---

## 19. Intermediate Lots

### `intermediate_lots`

Fields:

- product_id
- source_batch_id
- lot_code/display label
- produced_quantity
- current_quantity
- uom
- storage_location_id
- status
- produced_at
- expiry/bb later

Intermediate lots can be consumed by later production or packing.

Examples:

- cut paneer
- PAN111
- recovered cream
- pure butter
- cream-cheese filling
- cut halloumi

---

## 20. Transformations / Cutting

Use a generic transformation model or domain-specific tables.

Recommended generic approach:

### `transformations`

- transformation_type (`cutting`, `blending`, `filling`, `coating`, `frying`, etc.)
- occurred_at
- performed_by
- status
- notes

### `transformation_inputs`

- transformation_id
- source_intermediate_lot_id
- quantity
- uom

### `transformation_outputs`

- transformation_id
- product_id
- quantity
- uom
- destination_location_id
- generated_intermediate_lot_id

This supports batch genealogy without creating a separate table for every process.

For high-frequency workflows, domain-specific helper views/API endpoints can simplify UI.

---

## 21. Inventory Ledger

Prefer an immutable movement ledger.

### `stock_movements`

Fields:

- id
- material/product_id
- sku_id nullable
- source_lot_id nullable
- intermediate_lot_id nullable
- source_location_id nullable
- destination_location_id nullable
- movement_type
- quantity
- uom
- reference_type
- reference_id
- occurred_at
- created_by

Examples:

- receive
- transfer
- consume
- produce
- pack
- handover
- return
- waste
- correction

### Balance strategy

Prefer deriving balances from movements or maintaining a transactionally updated balance table/materialized view.

Do not permit arbitrary stock balance edits.

---

## 22. Packing Runs

### `packing_runs`

- sku_id
- started_at
- completed_at
- storage_location_id
- status
- operator/team
- cases_produced
- loose_units_produced
- notes

### `packing_run_sources`

- packing_run_id
- intermediate_lot_id
- quantity_consumed
- uom

Must support multiple source intermediate lots.

### `packing_material_usage`

- packing_run_id
- packaging_material_id
- standard_quantity
- actual_quantity
- uom

---

## 23. Finished Stock

Finished stock should also be represented by stock movements.

Optional convenience entity:

### `finished_stock_lots`

- sku_id
- packing_run_id
- batch/display code
- case_qty
- loose_unit_qty
- storage_location_id
- status

Do not duplicate truth if stock movements already contain all information; use views if possible.

---

## 24. Waste

### `waste_events`

- material/product_id
- batch_id nullable
- intermediate_lot_id nullable
- packing_run_id nullable
- quantity
- uom
- waste_reason_id
- occurred_at
- created_by
- notes

### `waste_reasons`

Configurable master:

- milk_spillage
- rejected_milk
- damaged_packaging
- giveaway
- process_loss
- rejected_popper
- contamination
- other

PAN111 and recovered cream must not be stored as waste.

---

## 25. Temperature Logs

### `temperature_logs`

- storage_location_id
- measured_at
- temperature_c
- captured_by
- is_out_of_range
- notes optional

`is_out_of_range` should be derived from location temperature profile at insertion time or query time.

Phase 1 does not require excursion case management.

---

## 26. Utility Logs

### `utility_types`

- diesel
- paraffin
- gas
- electricity

### `utility_logs`

- utility_type_id
- period_start
- period_end
- quantity
- uom
- unit_cost nullable
- total_cost nullable
- entry_type (`consumption`, `meter_reading`)
- reading_start nullable
- reading_end nullable
- notes

---

## 27. Utility Cost Allocation

### `cost_allocation_periods`

Example weekly period.

### `utility_allocations`

- allocation_period_id
- utility_log_id
- product_family_id/product_id
- allocation_basis
- allocated_quantity/cost
- method_version

Allocation must be explicit and traceable.

Do not present allocated utility usage as directly measured batch consumption.

---

## 28. Costing Tables

### `material_costs`

- material/product_id
- effective_from
- cost_per_uom
- source

### `standard_costs`

- product/sku
- effective_from
- standard_material_cost
- standard_packaging_cost
- standard_utility_cost
- other components

### `actual_cost_snapshots` or calculated views

Prefer calculated services/views from:

- actual inputs
- movements
- output yields
- waste
- packaging
- utility allocation

Do not persist derived actual cost prematurely unless needed for historical price snapshots/performance.

---

## 29. Co-product Cost Allocation

Do not implement arbitrary cost splitting until the business rule is approved.

Architecture must preserve:

- all batch inputs
- all primary/recovered outputs
- quantities
- source relationships
- actual prices

This permits later methods such as:

- relative sales value
- standard credit value
- weight-based allocation
- management-defined allocation

---

## 30. Distribution Handover

### `handovers`

- handover_number
- created_at
- created_by
- status (`draft`, `sent`, `confirmed`, `cancelled`)
- confirmed_at
- confirmed_by/recipient_name
- notes

### `handover_lines`

- handover_id
- sku_id
- cases
- loose_units
- quantity_equivalent optional

Confirmation must generate the stock movement out of production-controlled finished stock.

---

## 31. Distribution Returns

### `distribution_returns`

- original_handover_id nullable
- returned_at
- reason
- status
- recorded_by

### `distribution_return_lines`

- sku_id
- cases
- loose_units
- disposition

Returned damaged/rejected stock should not automatically become saleable stock.

---

## 32. Reconciliation

Recommended service/view outputs:

### Batch reconciliation

Inputs vs outputs + waste + residual

### Intermediate reconciliation

Produced vs consumed vs remaining

### Packing reconciliation

Intermediate consumed vs finished packed + waste + remaining

### Weekly milk reconciliation

Received milk:

- consumed by production
- rejected
- spilled
- remaining
- other accounted movements
- unexplained variance

Reconciliation should be generated from underlying transactions rather than entered manually where possible.

---

## 33. FIFO Query

Provide a query/service that returns eligible intermediate lots ordered by:

1. production date/time ascending
2. shift ascending
3. round ascending

Packing UI should recommend the oldest.

If user chooses another lot:

- show warning,
- require optional reason later,
- do not hard-block initially.

---

## 34. API / Service Boundaries

If using a server/API layer, recommended endpoints/actions include:

### Auth

- current user/profile
- role checks

### Master Data

- list/create/update products
- list/create/update SKUs
- recipes/versioning
- storage locations
- waste reasons

### Receiving

- create milk lot
- allocate milk lot
- create cream lot

### Production

- create shift
- create production round
- record batch inputs
- record batch output
- update open batch status
- complete/lock batch

### Transformation

- create cutting transaction
- create blend/fill/crumb/fry transaction
- record intermediate output

### Inventory

- transfer stock
- consume stock
- current stock by location
- genealogy lookup

### Packing

- create packing run
- select source lots
- record cases/loose units
- packaging usage
- complete packing run

### Controls

- waste event
- temperature log
- utility log

### Handover

- create handover
- confirm handover
- record return

### Reporting

- production board
- weekly milk reconciliation
- yield report
- waste report
- inventory report
- cost report
- utility report

### Correction

- owner correction transaction

---

## 35. UI Screen Map

Phase 1 screens:

1. Login
2. Dashboard
3. Digital Production Board
4. Milk Receiving
5. Milk Lot Detail
6. Shift Detail
7. Production Round Detail
8. Cutting / Allocation
9. Intermediate Stock
10. Packing Run
11. Finished Stock
12. Ingredient Inventory
13. Packaging Inventory
14. Stock Transfer
15. Waste Entry
16. Temperature Log
17. Utilities
18. Distribution Handover
19. Weekly Reconciliation
20. Yield Report
21. Cost Report
22. Product Master
23. Recipe Master
24. Storage Locations
25. Users / Roles
26. Audit History
27. Owner Correction UI

Prioritize workflow speed over dashboard polish.

---

## 36. Validation Rules

Examples:

- Quantities must be positive unless explicit adjustment type allows signed values.
- Completed/locked records cannot be updated by production managers.
- Owner correction requires reason.
- Paneer cannot enter `frozen_ready_for_packing` unless cutting has been recorded, except explicit configured exception.
- MPAN010/RPAN010 may follow fresh-pack workflow.
- Packing must consume available intermediate stock.
- Packing may consume multiple lots.
- Finished case + loose unit totals must respect SKU configuration.
- FIFO warning should appear when older eligible stock exists.
- Waste must use a configured reason.
- Temperature out-of-range flag must be calculated from location profile.
- Handover cannot exceed available finished stock.
- Recipe version used by a batch is immutable after batch completion.

---

## 37. Concurrency and Transactionality

Critical operations must run transactionally:

- stock transfer
- production completion
- packing completion
- handover confirmation
- owner correction
- waste posting

Avoid read-then-write balance logic that can oversubscribe stock.

Use PostgreSQL transactions, functions, or RPC where appropriate.

---

## 38. Soft Delete vs Hard Delete

Business transactions:

- do not hard delete
- use cancelled/voided status if necessary
- audit cancellation

Master data:

- prefer `active = false`
- do not delete products/recipes referenced historically

---

## 39. Date/Time

Use `timestamptz` in PostgreSQL.

Display in factory-local South African time.

Store timezone-aware UTC values.

Do not encode shift identity solely from timestamps; retain explicit shift numbers.

---

## 40. Units

Use a normalized unit-of-measure system.

Required units include:

- L
- mL
- kg
- g
- piece
- packet
- case
- bucket
- kWh or meter units as appropriate

Avoid mixing raw numeric values without UOM.

Use conversion only within compatible dimensions.

---

## 41. Security

- Supabase Auth sessions
- RLS enabled
- no secret/service role keys in browser
- environment variables excluded from git
- owner-only functions checked server-side
- recipe-confidential access enforced server-side/RLS
- audit not client-trusted

---

## 42. Seed Data

Initial seed data should include:

### Roles

- production_manager
- owner

### Locations

- Silo
- BMC 1
- BMC 2
- Holding Tank
- IBC Storage
- Bulk Ingredient Store
- Intermediate Ingredient Store
- Production
- Chiller
- Intermediate Freezer
- Finished Production Stock
- Distribution Handover

### Product families

- Paneer
- Halloumi
- Butter
- Ghee
- Poppers
- Cream / Intermediates

### Known finished SKUs

Seed only known confirmed codes/configurations from `PRODUCT_SPEC.md`.

### Waste reasons

Seed common reasons from specification.

### Temperature profiles

- Chiller 3–5°C
- Freezer approx. -18°C target profile

Do not seed unknown recipe secrets.

---

## 43. Testing Strategy

### Unit tests

- recipe scaling
- quantity/unit conversions
- yield calculations
- standard vs actual variance
- FIFO selection
- case/loose packet calculations
- temperature range checks

### Integration tests

- milk receipt → batch → intermediate → packing → handover
- stock transaction integrity
- multi-source packing
- PAN111 → JP filling genealogy
- recovered cream → butter → ghee genealogy
- owner correction of locked batch
- RLS role enforcement

### End-to-end tests

At least:

1. Production manager logs in and creates Sunday milk lot.
2. Creates shift and paneer round.
3. Records paneer output.
4. Records cutting and PAN111.
5. Freezes intermediate stock.
6. Packs oldest eligible batch.
7. Records loose packets/cases.
8. Creates handover.
9. Owner views reconciliation.
10. Owner corrects a locked record with reason.

### Factory acceptance tests

Use actual Vejoy production scenarios, not synthetic-only tests.

---

## 44. Observability / Error Handling

At minimum:

- structured server logs
- human-readable error messages
- database constraint errors mapped to useful UI messages
- capture unexpected failures with request/user context, excluding recipe secrets where inappropriate

---

## 45. Performance

Phase 1 dataset size is modest.

Prioritize correctness.

Index:

- foreign keys
- status
- occurred_at/created_at
- lot_code
- batch_code
- product/SKU
- storage location
- source lot
- intermediate lot

Avoid premature denormalization.

---

## 46. Migration Strategy

All schema changes should be committed to GitHub.

Use Supabase migrations.

Never make production-only manual schema changes without a matching migration.

Suggested conventions:

- one feature migration group at a time
- seed scripts versioned
- migrations reviewed before production deployment

---

## 47. Definition of Done for a Feature

A feature is not done until:

- database migration exists
- RLS/security is defined
- UI workflow exists
- business validation exists
- audit behavior exists where relevant
- automated tests cover core rules
- error/loading/empty states exist
- acceptance criteria pass
- factory wording matches Vejoy terminology
- documentation is updated if business rules changed
