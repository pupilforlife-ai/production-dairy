begin;

create type public.app_role as enum ('production_manager', 'owner');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  role public.app_role not null default 'production_manager',
  active boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid,
  action text not null,
  actor_user_id uuid references auth.users(id),
  occurred_at timestamptz not null default now(),
  old_data jsonb,
  new_data jsonb,
  reason text,
  request_id uuid
);

create index audit_events_entity_idx on public.audit_events (entity_type, entity_id);
create index audit_events_occurred_at_idx on public.audit_events (occurred_at desc);
create index audit_events_actor_idx on public.audit_events (actor_user_id);

create table public.corrections (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid not null,
  field_or_measure text not null,
  adjustment_value numeric,
  replacement_value jsonb,
  reason text not null check (length(trim(reason)) > 0),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  check (adjustment_value is not null or replacement_value is not null)
);

create index corrections_entity_idx on public.corrections (entity_type, entity_id);

create or replace function public.current_user_role()
returns public.app_role
language sql stable security definer set search_path = ''
as $$
  select role from public.profiles where id = auth.uid() and active = true;
$$;

revoke all on function public.current_user_role() from public;
grant execute on function public.current_user_role() to authenticated;

create or replace function public.is_owner()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.current_user_role() = 'owner'::public.app_role, false);
$$;

revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(coalesce(new.email, ''), '@', 1)),
    case
      when lower(new.email) = 'production-dairy@vejoy.co.za' then 'owner'::public.app_role
      else 'production_manager'::public.app_role
    end,
    lower(new.email) = 'production-dairy@vejoy.co.za'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.set_profile_update_metadata()
returns trigger
language plpgsql security invoker set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger profiles_set_update_metadata
before update on public.profiles
for each row execute function public.set_profile_update_metadata();

create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare record_id uuid;
begin
  if tg_op = 'DELETE' then record_id := old.id; else record_id := new.id; end if;
  insert into public.audit_events (entity_type, entity_id, action, actor_user_id, old_data, new_data)
  values (
    tg_table_name,
    record_id,
    lower(tg_op),
    auth.uid(),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger profiles_audit
after insert or update or delete on public.profiles
for each row execute function public.audit_row_change();

create or replace function public.audit_correction_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.audit_events (entity_type, entity_id, action, actor_user_id, new_data, reason)
  values ('correction', new.id, 'insert', auth.uid(), to_jsonb(new), new.reason);
  return new;
end;
$$;

create trigger corrections_audit
after insert on public.corrections
for each row execute function public.audit_correction_insert();

insert into public.profiles (id, display_name, role, active)
select
  id,
  coalesce(raw_user_meta_data ->> 'display_name', split_part(coalesce(email, ''), '@', 1)),
  case
    when lower(email) = 'production-dairy@vejoy.co.za' then 'owner'::public.app_role
    else 'production_manager'::public.app_role
  end,
  lower(email) = 'production-dairy@vejoy.co.za'
from auth.users
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.audit_events enable row level security;
alter table public.corrections enable row level security;

create policy profiles_select_self_or_owner on public.profiles for select to authenticated
using (id = auth.uid() or public.is_owner());

create policy profiles_owner_update on public.profiles for update to authenticated
using (public.is_owner()) with check (public.is_owner());

create policy audit_events_owner_select on public.audit_events for select to authenticated
using (public.is_owner());

create policy corrections_owner_select on public.corrections for select to authenticated
using (public.is_owner());

create policy corrections_owner_insert on public.corrections for insert to authenticated
with check (public.is_owner() and created_by = auth.uid());

revoke insert, update, delete on public.audit_events from anon, authenticated;
revoke insert, update, delete on public.corrections from anon;
revoke update, delete on public.corrections from authenticated;

commit;
