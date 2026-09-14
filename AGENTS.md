# Production Dairy workflow

This repo uses a two-branch workflow for Codex-assisted development.

## Branch roles

- `main` is the local working and refinement branch.
  - Use it for localhost development.
  - Use it for experiments, unfinished feature work, UI refinement, and debugging.
  - New work should normally start from `main`.
- `beta` is the clean testing/deployment branch.
  - Do not work directly on `beta` unless the user explicitly asks for an urgent beta hotfix.
  - Move only selected, approved work from `main` to `beta`.
  - Deploy beta only from the `beta` branch.

## Required checks before edits

- Always check the current branch and working tree before changing files:
  - `git status --short --branch`
- If the task is normal development or refinement and the repo is not on `main`, ask before switching or clearly explain the switch.
- If the user asks to push/test/deploy to beta, switch to `beta` only for that release step, then cherry-pick or merge the approved commits from `main`.

## Release process to beta

When the user says to push a completed feature to beta:

1. Confirm the intended commit(s) or summarize the selected local changes.
2. Run relevant checks, typically:
   - `npm run typecheck`
   - `npm run build:beta`
   - `npm test -- --watch=false`
3. Switch to `beta`.
4. Cherry-pick or merge only the approved commit(s) from `main`.
5. Push `beta`.
6. Deploy the beta Vercel project.
7. Point `https://beta-production-dairy.vercel.app` at the new deployment.
8. Return to `main` for continued development unless the user asks otherwise.

## Repository constraints

- Use the existing repo at `/Users/siddhant_arora/production-dairy`.
- Do not initialize a new repo.
- Preserve user work in the worktree. Do not discard or reset changes unless the user explicitly asks.
- Keep beta data safe. UI/app deployments should not overwrite production data unless a migration or database action is explicitly part of the requested change.

## Current baseline at the time this file was added

- `main` was fast-forwarded to the current tested `beta` state.
- Current shared baseline commit: `aa23251 Show intermediate stock in beta navigation`.
