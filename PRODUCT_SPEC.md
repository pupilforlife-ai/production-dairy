# Vejoy Production Management System — Product Specification

**Document:** `PRODUCT_SPEC.md`  
**Version:** 1.0  
**Status:** Working source of truth for Phase 1  
**Company:** Vejoy, South Africa  
**Application type:** Internal responsive web application  
**Primary users:** Production Managers, Directors/Owners

---

## 1. Product Purpose

The Vejoy Production Management System is an internal manufacturing operations application for recording, tracing, reconciling, and costing production activity from receipt of raw materials through handover of finished goods to the separate distribution branch.

The system is not intended to replace Vejoy's existing distribution application.

Its primary purpose is to answer:

- What raw materials were received?
- What was planned and actually produced?
- Which milk/cream lots fed each production round?
- What intermediate materials were created?
- How were intermediate materials cut, transformed, frozen, packed, and handed over?
- What ingredients and packaging were consumed?
- What was wasted, recovered, or left unexplained?
- What was the expected versus actual yield?
- What did each product/batch/unit/case cost?
- Where is stock currently stored?
- Who created, changed, corrected, or approved each record?

---

## 2. Product Principles

1. **Digitise existing factory practice before redesigning it.**
2. **Keep Phase 1 practical.** Manual batch entry, manual temperature entry, and manual inventory transactions are acceptable.
3. **Preserve traceability.** Finished goods should be traceable back through packing, intermediate stock, production rounds, and source lots.
4. **Avoid false precision.** Utility and other allocated costs must be marked as allocated where they are not directly measured.
5. **Do not hard-code products or recipes.** Product, SKU, case configuration, recipes, tolerances, and workflows should be configurable master data.
6. **Do not overwrite history.** Corrections to completed records are owner-only and must preserve an audit trail.
7. **Support gradual process maturity.** QC, lot traceability, QR labels, hardware integrations, and stricter controls can be added later.

---

## 3. Scope Boundary

### In scope

Raw material receipt → production → intermediate storage → transformations → freezing → packing → finished stock → production-to-distribution handover.

Supporting functions:

- Product and recipe master data
- Ingredient and packaging inventory
- Waste and recovery
- Yield and reconciliation
- Cold-chain logging
- Fuel and electricity capture
- Costing
- Audit trail
- Management dashboards

### Out of scope for Phase 1

- Distribution operations after handover
- Barcode/QR scanning
- Automatic label printing
- Scale integration
- Flow meter integration
- Machine/PLC integration
- Advanced laboratory/QC workflow
- Automated supplier lot enforcement
- Predictive production planning
- Automatic purchasing
- Maintenance management
- Detailed labour tracking
- Advanced cold-chain excursion investigations
- Offline sync
- AI features

---

## 4. Users and Permissions

### Production Manager

Primary operational user.

Can:

- Receive milk and cream lots
- Create and update production records while open
- Create shifts and production rounds
- Record teams and staff involved
- Record output, cutting, freezing, packing, waste, stock movements, temperatures, utilities, and handovers
- View production, yield, inventory, and operational reports
- Use recipes required for production

Cannot:

- Silently change locked/completed records
- Perform owner-only corrections
- Change sensitive system administration settings reserved for owners

### Director / Owner

Oversight and administration role.

Can:

- View all dashboards and reports
- View costing
- View audit history
- Maintain restricted master data as permitted
- Correct completed records
- Manage users/permissions
- Access confidential recipe information
- Perform future approvals when approval rules are defined

### Future roles

The architecture should allow later addition of:

- Production Operator
- Storekeeper
- QC
- Factory Manager
- Distribution Handover Recipient
- Accountant

These are not required as Phase 1 active roles.

---

## 5. Factory Operating Model

- One factory in South Africa.
- Milk is generally received Sunday evening.
- Weekly raw milk receipt is typically approximately 20,000–30,000 L.
- Production begins immediately on Sunday and continues over the following 3–4 days.
- Factory operates 6 days per week over multiple shifts.
- There is only one production manager responsible for a 24-hour production environment.
- Production decisions are made by the owner and production manager based on:
  - demand,
  - finished stock from Friday stocktake,
  - milk availability,
  - management judgment.
- Planning is currently informal/impromptu.

---

## 6. Departments / Areas Relevant to the System

- Milk reception
- Processing
- Packing
- Intermediate cold storage
- Finished stock / production-controlled storage
- QC
- Stores
- Administration

---

## 7. Raw Milk Receiving

### Current model

A milk supplier delivers raw milk on Sunday.

The production manager:

- receives the milk,
- records the received quantity in litres,
- accepts/rejects as applicable,
- uses the milk reception date as the current parent batch code.

### Typical milk storage allocation

Milk can be distributed across:

- 10,000 L silo
- 3,000 L BMC #1
- 3,000 L BMC #2
- 2,500 L holding tank
- approximately 2,000 L transferred directly to production
- 1–10 IBCs of 1,000 L each depending on milk received

### Product requirement

The system must support:

**Milk Lot → one or more vessel/location allocations → one or more production rounds**

Vessel-level tracking should be supported but may be optional in early Phase 1 to avoid excessive data entry.

---

## 8. Batch Hierarchy

The application must distinguish multiple production identities rather than use one generic batch concept.

### Level 1 — Source Lot

Examples:

- Sunday raw milk lot
- Purchased cream lot
- Ingredient receipt lot later

### Level 2 — Shift

Sunday night is Shift 1.

### Level 3 — Production Round

Each paneer production round is a separate record.

Current human-readable identity:

`Milk Lot + Shift + Round + Product Type`

Example:

`230826 / Shift 4 / Round 3 / D`

Potential internal key:

`230826-S04-R03-D`

System-generated batch numbering is deferred; manual identifiers remain acceptable initially.

### Level 4 — Intermediate Output

Examples:

- Malai paneer
- Rozana paneer
- PAN111
- SPP-cut paneer
- Raw halloumi
- Cut halloumi
- Recovered cream
- Pure butter
- Cream-cheese filling
- Coated/frozen poppers

### Level 5 — Packing Run

A packing run converts eligible intermediate stock into finished SKU stock.

A packing run must allow one or multiple source batches because batches can be accidentally mixed.

### Level 6 — Finished Stock

Finished SKU stock available for handover.

---

## 9. Digital Production Board

The existing factory whiteboard is a critical workflow and should be digitised first.

### Current board fields

Header / shift level:

- Shift number
- Batch code (usually milk reception date)
- Team members involved in shift

Round level:

- Serial number / round number
- Paneer type
  - `D` = Malai / Full Fat
  - `C/S` = Rozana / Medium Fat
- Status
- Cut by
- Cutting type
- Packing result

### Recommended digital board fields

- Milk lot
- Shift
- Round
- Product/type
- Status
- Team
- Cut by
- Cutting allocation
- Gross manufactured output
- Intermediate stock balance
- Packed quantity
- Cases
- Loose packets
- Notes

### Initial status model

Configurable by product family.

Paneer example:

Scheduled → In Production → Pressing → Ready for Cutting → Cut → Freezing → Frozen / Ready for Packing → Part Packed → Packed → Ready for Handover → Handed Over

The app should not hard-block every exception initially.

---

## 10. Product Master Model

Products should be represented hierarchically.

**Product Family → Manufactured Product → Variant → Finished SKU → Packaging Configuration**

Product Master should support:

- Product code
- Product name
- Product family
- Product class:
  - raw material
  - intermediate material
  - finished product
- Variant/type
- Fixed-weight or variable-weight
- Unit weight
- Pieces per packet
- Packets per case
- Case weight
- Storage condition
- Shelf life / BB rules later
- Active/inactive
- Recipe reference
- Expected yield rules
- Packaging specification

Case configurations must not be hard-coded because some products can be sold in varying 10 kg, 15 kg, or 20 kg case formats.

---

## 11. Known Product Genealogy

### 11.1 Paneer

#### Malai / Full Fat Paneer (`D`)

Known SKUs/variants include:

- MPAN100 — 1 kg × 15 packets/case
- MPAN400 — 400 g × 24 packets/case
- MPAN200 — 200 g × 24 packets/case
- VJPAN — 200 g × 20 packets/case
- MPAN010 — fresh paneer block, generally 400 g units; case configuration can vary
- PAN101 / PAN111 identifiers require later master-data cleanup where applicable

#### Rozana / Medium Fat Paneer (`C/S`)

Known SKUs/variants include:

- RPAN100 — 1 kg × 15 packets/case
- RPAN400 — 400 g × 24 packets/case
- RPAN200 — 200 g × 24 packets/case
- RPAN010 — fresh paneer block, generally 400 g units; case configuration can vary

### Paneer operational rule

A typical paneer round currently uses 500 L milk.

Typical gross paneer output is approximately 70 kg, but actual yield varies.

Paneer must follow:

**Press → Cut → Freeze → Pack**

Paneer must **not** be frozen before cutting.

Fresh MPAN010 / RPAN010 are exceptions that are packed fresh.

### Cutting

Cutting options include:

- 400 g format
- 200 g format
- blocks
- SPP pieces
- other configured cut types

Cutting should be a recorded transformation/allocation transaction.

### PAN111

PAN111 is recovered usable paneer material arising from:

- offcuts,
- broken pieces,
- insufficient pressing,
- soft paneer that crumbles during cutting.

PAN111 is **not ordinary waste**.

It is an internally produced intermediate material and is used in Jalapeño Popper cream-cheese filling.

---

## 12. Spicy Paneer Poppers (SPP)

Typical input:

- Paneer from approximately one Rozana production round
- Input batch can vary, e.g. ~64–78 kg

Known coating materials:

- 800 g Iyababa spice mix
- 200 g Predust
- Iyababa + water wet coating
- Adajio roasted breadcrumbs

Process:

Rozana paneer → cut to SPP size → coating → freeze → flash fry → freeze → pack

Frying standard:

- approximately 185°C
- approximately 20 seconds

Piece weight quality rule:

- Target: 165 g per 8 pieces
- Acceptable: 150–180 g per 8 pieces

Typical example:

- 75 kg batch
- ~450 packets
- 37 cases + 6 loose packets

Finished pack:

- 8 pieces per packet
- 12 packets per case

Rejected poppers are discarded as waste and are not reworked.

---

## 13. Halloumi

Current batch size is generally 240 L, but may move to ~500 L.

Known process:

1. Milk at approximately 4°C
2. CaCl2 solution added
3. Milk brought to ~34°C
4. Rennet added
5. Curd set ~30 minutes
6. Curd cut
7. Slowly heated to ~42°C over ~40 minutes while curd is gently lifted
8. Curd removed into presses
9. Whey remains in vessel and is heated to ~90°C
10. Pressed halloumi cut to smaller pieces
11. Halloumi cooked in hot whey until floating
12. Removed, cooled, salted
13. Held in chiller 4–6 hours
14. Either:

- vacuum packed and sold by weight, or
- cut for halloumi poppers

Exact recipe quantities must remain recipe master data, not business logic.

### Halloumi Poppers

Typical input:

- approximately two 240 L halloumi rounds
- cut halloumi batch typically around 45–60 kg

Process:

Cut halloumi → Predust → batter mix + water → Adajio → freeze → flash fry → freeze → pack

Piece-weight guide:

- 8 pieces approximately 120–140 g

Finished pack:

- 8 pieces/packet
- 12 packets/case

Rejected product is discarded.

---

## 14. Cream

### Internally recovered cream

Currently recovered from Rozana paneer production.

Future processes may also yield cream, such as:

- mozzarella,
- amasi,
- halloumi.

The model must therefore allow any eligible production process to generate a cream intermediate.

Internally recovered cream is pooled and generally converted to butter, then primarily to ghee.

### Purchased cream

Purchased in lots generally between 200–800 L, with up to ~1,000 L/week.

Each receipt normally becomes its own cream lot.

Multiple cream lots may exceptionally be merged for butter production.

---

## 15. Butter

Pure butter is produced from cream and weighed after production.

### Purchased-cream butter route

Purchased cream → pure butter → blended products

Standard small blended-butter production formula:

- 16.5 kg pure butter
- 5 kg butter replacer

Salt is added while blending when required.

Blended butter is approximately 70% pure butter / 30% replacer operationally, but staff should use the fixed formula rather than manually calculate ratios.

### Internal-cream butter route

Recovered cream → pure butter → primarily ghee

Leftover pure butter may become:

- PUBB
- PUBBB
- PSBBB

### Finished butter products

- PUBB — pure/unsalted butter balls
- PUBBB — blended butter balls
- PSBBB — blended salted butter balls
- BB05 — blended salted butter bricks

Known configurations:

- PUBB / PUBBB / PSBBB:
  - 3 packets × 12 balls
  - each ball 500 g
  - 18 kg/case
- BB05:
  - 30 × 500 g bricks
  - 15 kg/case

Butter products are frozen before packing.

---

## 16. Ghee

Ghee is produced only from butter.

Standard production formula:

- 92.5 kg pure butter
- 12.5 kg AF oil
- total formula input = 105 kg

Expected yield:

- approximately 70%
- theoretical output ≈ 73.5 kg

Finished ghee:

### 400 g

- 27 buckets/case
- 10.8 kg/case

### 1.5 kg

- 6 buckets/case
- 9 kg/case

The system must compare theoretical versus actual ghee yield.

---

## 17. Jalapeño Poppers (JP)

Raw jalapeños:

- received in 5 kg buckets
- typical batch = 12 buckets = ~60 kg
- batch yields roughly 1,200–1,400 pieces

Cream-cheese filling:

- 20 kg PAN111
- 1 L fresh cream
- 220 g salt
- 22 g black pepper

Process:

PAN111 + filling ingredients → cream-cheese filling → fill jalapeños → freeze → crumb/coating process → freeze → flash fry → freeze → pack

Crumbing process is broadly the same as halloumi poppers.

Frying:

- ~185°C
- ~20 seconds

Typical output:

- ~220 packets
- 18 cases + 4 loose packets

Finished pack:

- 6 pieces/packet
- 12 packets/case

Rejected units are discarded.

---

## 18. Recipe System

Recipes are fixed by product and scale proportionally with batch size.

Requirements:

- Recipe header
- Recipe version
- Recipe component lines
- Base quantity / formula basis
- Units
- Optional tolerance
- Active/effective version
- Access restrictions
- Historical recipe retention

A batch must retain the exact recipe version used.

Recipes must support confidential information.

Do not expose recipe ingredients to users who do not require them.

No recipe history may be overwritten.

---

## 19. Inventory Locations

### Milk

- Silo
- BMC 1
- BMC 2
- Holding tank
- IBC storage
- Production

### Ingredients

- Bulk shipping-container store
- Intermediate ingredient store
- Production floor / consumed

### Cold Storage

- Chiller: target 3–5°C
- Intermediate freezer/refrigerated container
- Finished production stock awaiting distribution handover

The distribution branch's walk-in freezer is managed by the separate distribution app.

---

## 20. Ingredient Issuing Model

Because there is one production manager responsible for a 24-hour environment, manager approval for every material issue is not practical.

Preferred operational model:

**Bulk Store → Intermediate Production Store → Production Consumption**

Staff can consume approved ingredients from the intermediate store.

The production manager performs replenishment/reconciliation.

Ingredients may be consumed across several production batches.

---

## 21. Stock Movement Model

Inventory should change through stock movements, not direct balance edits.

Examples:

- Bulk Store → Intermediate Store
- Intermediate Store → Production Consumption
- Production Output → Chiller
- Production Output → Intermediate Freezer
- Intermediate Stock → Transformation Batch
- Intermediate Stock → Packing Run
- Finished Stock → Distribution Handover
- Distribution Return → Rejected/returned stock disposition

Each stock movement should capture:

- material/product
- quantity
- unit
- source location
- destination location
- source batch/lot where applicable
- reference transaction
- date/time
- user

---

## 22. FIFO

Packing staff should normally select the earliest eligible frozen batch first.

The system should:

- recommend the oldest eligible batch,
- warn when a newer batch is selected while an older batch remains,
- allow an override rather than hard-block production.

---

## 23. Packing

Packing must support:

- cases
- loose packets
- variable case configurations
- one or multiple source batches
- packed quantity
- packaging consumption
- residual intermediate stock

Example:

`37 cases + 6 loose packets`

must remain represented as such.

The system should support conversion such as:

`12 loose packets → 1 case`

without treating it as new manufacturing output.

---

## 24. Waste and Recovery

### Recoverable material

Not waste:

- PAN111
- usable offcuts
- recovered cream
- other usable intermediates

### Waste examples

- milk spillage
- rejected milk
- damaged packaging
- product giveaway
- process loss
- broken/rejected poppers
- contamination/drop
- other configured reason

A waste event must record:

- batch/material
- quantity
- reason
- user
- date/time
- optional note

Future approval thresholds can be added later.

---

## 25. Yield and Reconciliation

The system must support:

### Batch yield

Example: 500 L milk → X kg paneer

### Percentage yield

Use Vejoy's operational formula

### Litres per kg

Example: milk litres used ÷ kg product

### Transformation yield

Example: butter input → ghee output

### Packing yield

Example: SPP batch → packets/cases

### End-of-production reconciliation

Current business practice includes reconciling:

- milk used
- paneer/halloumi yield
- litres per kg
- cream recovered
- ingredients used
- butter made
- ghee made
- butter derivatives
- scramble/PAN111
- packed finished output

### Weekly milk-lot reconciliation

The Sunday milk lot should reconcile:

Received milk = processed + remaining + rejected + spilled + other accounted movements

The system should calculate unexplained variance.

---

## 26. Cold Chain

### Storage rules

Chiller target:

- 3–5°C

Examples stored chilled:

- cream
- butter before processing
- ghee
- fresh/thawed paneer blocks
- raw halloumi
- selected ingredients

Other frozen products:

- approximately -18°C

### Temperature capture

- Built-in displays are read manually
- Current checks: ~4–6 times/day
- Phase 1: manual temperature entry
- System must flag readings outside configured range

Not required initially:

- detailed excursion investigation
- generator/solar workflow
- sensor integration

### Inventory level

Track stock by cold room/location, not rack/bin.

---

## 27. Utilities

Phase 1 utilities:

- Diesel
- Paraffin
- Gas
- Grid electricity

Capture frequency:

- generally weekly, especially Friday for diesel/gas
- electricity by meter readings/consumption

Water is out of scope initially.

Utility usage is not directly measured per machine or batch.

The costing system must therefore distinguish **allocated utility cost** from directly measured cost.

---

## 28. Distribution Handover

The production app ends at handover.

Handover should capture:

- date/time
- SKU
- cases
- loose packets if applicable
- production user
- recipient/confirmation
- notes

After confirmed handover:

- production finished-stock balance decreases
- distribution is responsible in its separate application

Distribution can return damaged/rejected goods.

Returned goods must be recorded with:

- product
- quantity
- reason
- date
- original handover reference if available
- disposition

Production remains responsible for damaged/rejected returns.

---

## 29. Costing

The system must calculate actual manufacturing cost.

Cost components may include:

- raw milk
- purchased cream
- milk powder
- ingredients
- packaging
- electricity
- diesel/paraffin
- gas
- labour later
- wastage
- maintenance later
- overhead later

### Standard / theoretical cost

Based on:

- standard formula
- standard yield
- standard packaging
- standard/expected cost inputs
- allocated utilities

### Actual cost

Based on:

- actual materials
- actual yield
- actual waste
- actual packaging consumption
- actual input prices
- actual allocated utilities

### Cost levels

- cost per production batch
- cost per kg intermediate product
- cost per transformation
- cost per finished packet/unit
- cost per case

### Co-product costing

The database must preserve enough information for later cost-allocation rules.

Examples:

- Rozana paneer + recovered cream
- PAN111 recovered from paneer cutting

The costing policy itself is a later business decision.

---

## 30. Audit and Corrections

Audit trail is mandatory from Phase 1.

Record:

- user
- action
- entity
- entity ID
- old value where relevant
- new value where relevant
- timestamp
- reason where applicable

Completed records should become locked.

Corrections:

- owner/director only
- correction must create an adjustment/correction record
- original record remains preserved

No silent historical edits.

---

## 31. Management Dashboard

Initial management priorities:

- Losses
- Yield
- Wastage
- Fuel consumption
- Power consumption
- Cold-chain management

Useful weekly metrics:

- Milk received
- Milk processed
- Milk remaining
- Paneer output
- Halloumi output
- Cream recovered
- Butter output
- Ghee output
- SPP / Halloumi Popper / JP output
- Finished stock awaiting handover
- Waste by reason
- Unexplained variance
- Standard vs actual cost
- Temperature exceptions
- Weekly utility consumption

---

## 32. Phase 1 Success Criteria

Phase 1 is successful when Vejoy can:

1. Replace the production whiteboard with the digital board for daily tracking.
2. Record a Sunday milk lot and trace production rounds to it.
3. Record manufactured intermediate output by round.
4. Record cutting and intermediate stock.
5. Apply FIFO guidance for packing.
6. Record cases and loose packets by source batch.
7. Track stock by production-controlled location.
8. Record ingredient/packaging consumption.
9. Record waste and recoverable intermediates separately.
10. Record temperature and utility readings.
11. Perform weekly milk-lot reconciliation.
12. Compare standard/theoretical and actual yield/cost.
13. Generate production-to-distribution handovers.
14. Preserve a full audit trail.
15. Prevent non-owner silent correction of completed history.

---

## 33. Known Open Questions / Decisions for Later

- Final normalized SKU codes for PAN101 / PAN111 and any duplicate codes
- Exact case configurations for MPAN010 / RPAN010 when customer format varies
- Exact expected yield standards for Malai vs Rozana
- Exact product-specific recipe data to load into Recipe Master
- Detailed approval thresholds
- Co-product cost allocation policy
- Standard utility allocation method
- Labour and overhead allocation method
- Shelf-life rules
- Detailed QC workflow
- Future batch/QR numbering convention
