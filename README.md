# Vejoy Production Management System

Internal responsive factory application for tracing production from raw-material receipt through finished-stock handover. Distribution after handover remains outside this application.

## Architecture baseline

- Angular 22 standalone application
- TypeScript 6
- Tailwind CSS 4
- Supabase Auth and PostgreSQL through `@supabase/supabase-js`
- Vitest through Angular's unit-test builder
- npm 10

The Phase 1 architecture is a modular monolith. Keep business rules in domain services and database migrations rather than UI components. Do not replace the existing Angular scaffold without an approved architectural decision.

## Project structure

```text
src/app/                 Angular application
src/app/services/        Shared infrastructure services
src/environment.ts       Browser-safe Supabase configuration
supabase/migrations/     Versioned database migrations (when initialized)
docs/                    Project and development conventions
```

Only a Supabase publishable/anonymous key may be used by the browser. Never place a service-role key or another secret in `src/environment.ts`.

## Quality commands

```bash
npm run typecheck
npm run format:check
npm run test:ci
npm run build
```

## Development server

To start a local development server, run:

```bash
ng serve
```

Once the server is running, open your browser and navigate to `http://localhost:4200/`. The application will automatically reload whenever you modify any of the source files.

## Code scaffolding

Angular CLI includes powerful code scaffolding tools. To generate a new component, run:

```bash
ng generate component component-name
```

For a complete list of available schematics (such as `components`, `directives`, or `pipes`), run:

```bash
ng generate --help
```

## Building

To build the project run:

```bash
ng build
```

This will compile your project and store the build artifacts in the `dist/` directory. By default, the production build optimizes your application for performance and speed.

## Running unit tests

To execute unit tests with the [Vitest](https://vitest.dev/) test runner, use the following command:

```bash
ng test
```

No end-to-end framework or Supabase migration workspace has been configured yet. Both should be introduced with the feature that first requires them, rather than implied by the baseline.

## Additional Resources

For more information on using the Angular CLI, including detailed command references, visit the [Angular CLI Overview and Command Reference](https://angular.dev/tools/cli) page.
