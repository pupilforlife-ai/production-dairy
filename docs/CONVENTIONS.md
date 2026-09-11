# Project conventions

## Naming

- TypeScript files use kebab-case; exported classes and types use PascalCase.
- Database tables and columns use `snake_case` and UUID primary keys.
- Display codes are business identifiers, never primary keys.
- PostgreSQL timestamps use `timestamptz`; the UI displays factory-local South African time.

## Application boundaries

- UI components manage presentation and user interaction.
- Domain services own calculations and workflow rules.
- Supabase access is wrapped in focused data services rather than scattered through components.
- Sensitive authorization is enforced by RLS and/or transactional database functions. UI role checks are only a usability aid.
- Completed business records are corrected through audited adjustments, not overwritten or deleted.

## Database workflow

1. Create versioned SQL in `supabase/migrations` using the Supabase CLI once the workspace is initialized.
2. Include tables, constraints, indexes, RLS, policies, and required seed changes in the feature migration.
3. Verify migrations against a local or approved development Supabase project.
4. Commit migration, application code, and tests as one coherent feature where practical.
5. Never make an unmatched production-only schema change.

## Feature structure

Group feature UI, domain types, and services by domain as the application grows. Shared infrastructure belongs under `src/app/core`; reusable presentation belongs under `src/app/shared`. Avoid creating abstractions before a real second use exists.

## Operational interface design

- Present operational data in a minimalistic row-and-column structure by default.
- Use one business record per row and stable, clearly labelled fields as columns so users can scan and compare records quickly.
- Represent parent records, such as shifts or milk receipts, as master rows with collapsible child rows or compact detail tables.
- Keep totals, balances, exceptions, and statuses visible within the table using footer rows, concise badges, and restrained highlighting.
- Prefer compact spacing, sticky headers, and horizontal scrolling where necessary instead of converting data into separate tiles.
- Do not use cards or tiles for operational datasets. They are reserved for a small number of genuinely high-level dashboard indicators and only when they improve understanding.
- Preserve traceability: summaries must be expandable to the shifts, rounds, SKUs, or other source records that produced them.

## Definition of done

- Business rules reference the product and technical specifications.
- Database security and audit behavior are defined where relevant.
- Loading, empty, success, and failure states are handled.
- Unit or integration tests cover the core rules.
- `npm run typecheck`, `npm run format:check`, `npm run test:ci`, and `npm run build` pass.
- Factory terminology matches Vejoy's language.
