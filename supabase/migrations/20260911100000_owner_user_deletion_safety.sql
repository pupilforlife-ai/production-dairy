begin;

create or replace function public.app_user_deletion_blockers(requested_user_id uuid)
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  foreign_key record;
  has_reference boolean;
  blockers text[] := array[]::text[];
begin
  for foreign_key in
    select
      namespace.nspname as schema_name,
      relation.relname as table_name,
      attribute.attname as column_name
    from pg_catalog.pg_constraint constraint_record
    join pg_catalog.pg_class relation
      on relation.oid = constraint_record.conrelid
    join pg_catalog.pg_namespace namespace
      on namespace.oid = relation.relnamespace
    join pg_catalog.pg_attribute attribute
      on attribute.attrelid = constraint_record.conrelid
      and attribute.attnum = constraint_record.conkey[1]
    where constraint_record.contype = 'f'
      and constraint_record.confrelid = 'auth.users'::regclass
      and constraint_record.confdeltype in ('a', 'r')
  loop
    execute format(
      'select exists (select 1 from %I.%I where %I = $1)',
      foreign_key.schema_name,
      foreign_key.table_name,
      foreign_key.column_name
    )
    into has_reference
    using requested_user_id;

    if has_reference then
      blockers := array_append(blockers, foreign_key.table_name);
    end if;
  end loop;

  return (select coalesce(array_agg(distinct blocker), array[]::text[]) from unnest(blockers) blocker);
end;
$$;

revoke all on function public.app_user_deletion_blockers(uuid) from public, anon, authenticated;
grant execute on function public.app_user_deletion_blockers(uuid) to service_role;

commit;
