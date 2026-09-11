# Supabase workflow

This directory contains versioned database migrations. The hosted project must not be changed manually without a matching migration.

## Applying migrations

1. Install or invoke the team's approved Supabase CLI.
2. Link the approved development project with `supabase link --project-ref <ref>`.
3. Review pending SQL with `supabase migration list` and a database diff.
4. Apply migrations to development with `supabase db push` only after approval.

## First owner bootstrap

The approved bootstrap owner identity is `production-dairy@vejoy.co.za`. The initial migration activates that exact verified Auth identity as owner, including when the Auth user exists before the migration runs. All other registrations remain inactive production-manager accounts.

If the approved owner identity changes, update the pending migration before it is applied. After the migration has been deployed, use a reviewed owner/admin operation rather than editing migration history.

Emergency manual bootstrap through a trusted admin channel:

```sql
update public.profiles
set role = 'owner', active = true
where id = '<confirmed-auth-user-uuid>';
```

Do not guess the UUID or bootstrap an owner from browser code.
