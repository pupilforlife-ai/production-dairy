begin;

create type public.shift_status as enum ('open', 'completed', 'cancelled');
create type public.production_status as enum (
  'scheduled',
  'in_production',
  'pressing',
  'ready_for_cutting',
  'cut',
  'freezing',
  'frozen_ready_for_packing',
  'part_packed',
  'packed',
  'ready_for_handover',
  'handed_over',
  'cancelled'
);

create table public.production_shifts (
  id uuid primary key default gen_random_uuid(),
  source_lot_id uuid not null references public.source_lots(id),
  shift_number integer not null check (shift_number > 0),
  started_at timestamptz not null,
  ended_at timestamptz,
  team_notes text,
  status public.shift_status not null default 'open',
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  check (ended_at is null or ended_at >= started_at),
  check ((status = 'completed' and ended_at is not null) or status <> 'completed'),
  unique (source_lot_id, shift_number)
);

create table public.shift_members (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.production_shifts(id),
  person_name text not null check (length(trim(person_name)) > 0),
  role_notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  unique (shift_id, person_name)
);

create table public.production_batches (
  id uuid primary key default gen_random_uuid(),
  batch_code text not null unique,
  parent_source_lot_id uuid references public.source_lots(id),
  shift_id uuid not null references public.production_shifts(id),
  round_number integer not null check (round_number > 0),
  product_id uuid not null references public.products(id),
  recipe_version_id uuid references public.recipe_versions(id),
  planned_input_quantity numeric check (planned_input_quantity is null or planned_input_quantity > 0),
  actual_primary_input_quantity numeric check (
    actual_primary_input_quantity is null or actual_primary_input_quantity > 0
  ),
  input_uom_id uuid references public.units_of_measure(id),
  gross_output_quantity numeric check (gross_output_quantity is null or gross_output_quantity >= 0),
  output_uom_id uuid references public.units_of_measure(id),
  cut_by text,
  cutting_allocation text,
  status public.production_status not null default 'scheduled',
  started_at timestamptz,
  completed_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  check (
    (actual_primary_input_quantity is null and input_uom_id is null)
    or (actual_primary_input_quantity is not null and input_uom_id is not null)
  ),
  check (
    (gross_output_quantity is null and output_uom_id is null)
    or (gross_output_quantity is not null and output_uom_id is not null)
  ),
  unique (shift_id, round_number)
);

create index production_shifts_started_at_idx on public.production_shifts (started_at desc);
create index production_shifts_status_idx on public.production_shifts (status);
create index shift_members_shift_idx on public.shift_members (shift_id);
create index production_batches_source_lot_idx on public.production_batches (parent_source_lot_id);
create index production_batches_shift_idx on public.production_batches (shift_id);
create index production_batches_product_idx on public.production_batches (product_id);
create index production_batches_status_idx on public.production_batches (status);
create index production_batches_created_at_idx on public.production_batches (created_at desc);

create or replace function public.validate_production_batch_milk_input()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  lot_quantity numeric;
  lot_uom uuid;
  lot_status public.source_lot_status;
  consumed_quantity numeric;
  shift_source_lot_id uuid;
begin
  select source_lot_id into shift_source_lot_id
  from public.production_shifts
  where id = new.shift_id;

  if not found then raise exception 'Production shift does not exist'; end if;
  if new.parent_source_lot_id is distinct from shift_source_lot_id then
    raise exception 'Production round source lot must match its shift source lot';
  end if;

  if new.parent_source_lot_id is null or new.actual_primary_input_quantity is null then
    return new;
  end if;

  select received_quantity, uom_id, status
  into lot_quantity, lot_uom, lot_status
  from public.source_lots
  where id = new.parent_source_lot_id
  for update;

  if not found then raise exception 'Source lot does not exist'; end if;
  if lot_status <> 'accepted' then raise exception 'Only accepted source lots can feed production'; end if;
  if new.input_uom_id <> lot_uom then raise exception 'Production input unit must match source lot unit'; end if;

  select coalesce(sum(actual_primary_input_quantity), 0)
  into consumed_quantity
  from public.production_batches
  where parent_source_lot_id = new.parent_source_lot_id
    and status <> 'cancelled'
    and id <> new.id;

  if consumed_quantity + new.actual_primary_input_quantity > lot_quantity then
    raise exception 'Production input cannot exceed source lot received quantity';
  end if;
  return new;
end;
$$;

create trigger production_batches_validate_milk_input
before insert or update on public.production_batches
for each row execute function public.validate_production_batch_milk_input();

alter table public.production_shifts enable row level security;
alter table public.shift_members enable row level security;
alter table public.production_batches enable row level security;

create policy production_shifts_authenticated_select on public.production_shifts
for select to authenticated using (public.current_user_role() is not null);
create policy production_shifts_operational_insert on public.production_shifts
for insert to authenticated with check (
  public.current_user_role() is not null and created_by = auth.uid()
);
create policy production_shifts_open_update on public.production_shifts
for update to authenticated
using (public.is_owner() or (public.current_user_role() is not null and locked_at is null))
with check (public.is_owner() or (public.current_user_role() is not null and locked_at is null));

create policy shift_members_authenticated_select on public.shift_members
for select to authenticated using (public.current_user_role() is not null);
create policy shift_members_operational_insert on public.shift_members
for insert to authenticated with check (
  public.current_user_role() is not null
  and created_by = auth.uid()
  and exists (
    select 1 from public.production_shifts
    where production_shifts.id = shift_members.shift_id
      and production_shifts.locked_at is null
  )
);

create policy production_batches_authenticated_select on public.production_batches
for select to authenticated using (public.current_user_role() is not null);
create policy production_batches_operational_insert on public.production_batches
for insert to authenticated with check (
  public.current_user_role() is not null and created_by = auth.uid()
);
create policy production_batches_open_update on public.production_batches
for update to authenticated
using (public.is_owner() or (public.current_user_role() is not null and locked_at is null))
with check (public.is_owner() or (public.current_user_role() is not null and locked_at is null));

grant select, insert, update on public.production_shifts, public.production_batches to authenticated;
grant select, insert on public.shift_members to authenticated;
revoke delete on public.production_shifts, public.shift_members, public.production_batches
from anon, authenticated;
revoke update on public.shift_members from anon, authenticated;

create or replace function public.create_production_shift(
  requested_source_lot_id uuid,
  requested_shift_number integer,
  requested_started_at timestamptz,
  requested_team_members text[],
  requested_team_notes text default null
)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  new_shift_id uuid;
  member_name text;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_shift_number <= 0 then raise exception 'Shift number must be positive'; end if;
  if coalesce(array_length(requested_team_members, 1), 0) = 0 then
    raise exception 'At least one team member is required';
  end if;

  insert into public.production_shifts (
    source_lot_id, shift_number, started_at, team_notes
  ) values (
    requested_source_lot_id, requested_shift_number, requested_started_at, requested_team_notes
  ) returning id into new_shift_id;

  foreach member_name in array requested_team_members loop
    if length(trim(member_name)) > 0 then
      insert into public.shift_members (shift_id, person_name)
      values (new_shift_id, trim(member_name));
    end if;
  end loop;

  return new_shift_id;
end;
$$;

revoke all on function public.create_production_shift(uuid, integer, timestamptz, text[], text)
from public;
grant execute on function public.create_production_shift(uuid, integer, timestamptz, text[], text)
to authenticated;

create trigger production_shifts_set_update_metadata
before update on public.production_shifts
for each row execute function public.set_profile_update_metadata();
create trigger production_batches_set_update_metadata
before update on public.production_batches
for each row execute function public.set_profile_update_metadata();

create trigger production_shifts_audit
after insert or update or delete on public.production_shifts
for each row execute function public.audit_row_change();
create trigger shift_members_audit
after insert or update or delete on public.shift_members
for each row execute function public.audit_row_change();
create trigger production_batches_audit
after insert or update or delete on public.production_batches
for each row execute function public.audit_row_change();

commit;
