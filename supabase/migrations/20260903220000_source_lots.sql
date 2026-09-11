begin;

create type public.source_lot_type as enum ('milk', 'purchased_cream');
create type public.source_lot_status as enum ('accepted', 'rejected', 'closed');

create table public.source_lots (
  id uuid primary key default gen_random_uuid(),
  lot_type public.source_lot_type not null,
  lot_code text not null unique,
  received_at timestamptz not null,
  supplier_id uuid references public.suppliers(id),
  received_quantity numeric not null check (received_quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  status public.source_lot_status not null,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  check ((status = 'closed' and locked_at is not null) or status <> 'closed')
);

create table public.source_lot_allocations (
  id uuid primary key default gen_random_uuid(),
  source_lot_id uuid not null references public.source_lots(id),
  storage_location_id uuid not null references public.storage_locations(id),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  movement_reference text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create index source_lots_received_at_idx on public.source_lots (received_at desc);
create index source_lots_status_idx on public.source_lots (status);
create index source_lots_supplier_idx on public.source_lots (supplier_id);
create index source_lot_allocations_lot_idx on public.source_lot_allocations (source_lot_id);
create index source_lot_allocations_location_idx
on public.source_lot_allocations (storage_location_id);

create or replace function public.validate_source_lot_allocation()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  lot_quantity numeric;
  lot_uom uuid;
  allocated_quantity numeric;
begin
  select received_quantity, uom_id into lot_quantity, lot_uom
  from public.source_lots
  where id = new.source_lot_id
  for update;

  if not found then raise exception 'Source lot does not exist'; end if;
  if new.uom_id <> lot_uom then raise exception 'Allocation unit must match source lot unit'; end if;

  select coalesce(sum(quantity), 0) into allocated_quantity
  from public.source_lot_allocations
  where source_lot_id = new.source_lot_id
    and id <> new.id;

  if allocated_quantity + new.quantity > lot_quantity then
    raise exception 'Allocated quantity cannot exceed received quantity';
  end if;
  return new;
end;
$$;

create trigger source_lot_allocation_validate
before insert or update on public.source_lot_allocations
for each row execute function public.validate_source_lot_allocation();

alter table public.source_lots enable row level security;
alter table public.source_lot_allocations enable row level security;

create policy source_lots_authenticated_select on public.source_lots for select to authenticated
using (public.current_user_role() is not null);
create policy source_lots_operational_insert on public.source_lots for insert to authenticated
with check (public.current_user_role() is not null and created_by = auth.uid());
create policy source_lots_open_update on public.source_lots for update to authenticated
using (public.is_owner() or (public.current_user_role() is not null and locked_at is null))
with check (public.is_owner() or (public.current_user_role() is not null and locked_at is null));

create policy source_lot_allocations_authenticated_select on public.source_lot_allocations
for select to authenticated using (public.current_user_role() is not null);
create policy source_lot_allocations_operational_insert on public.source_lot_allocations
for insert to authenticated with check (
  public.current_user_role() is not null
  and created_by = auth.uid()
  and exists (
    select 1 from public.source_lots
    where source_lots.id = source_lot_allocations.source_lot_id
      and source_lots.locked_at is null
  )
);

grant select, insert, update on public.source_lots to authenticated;
grant select, insert on public.source_lot_allocations to authenticated;
revoke delete on public.source_lots, public.source_lot_allocations from anon, authenticated;
revoke update on public.source_lot_allocations from anon, authenticated;

create trigger source_lots_set_update_metadata
before update on public.source_lots
for each row execute function public.set_profile_update_metadata();
create trigger source_lots_audit
after insert or update or delete on public.source_lots
for each row execute function public.audit_row_change();
create trigger source_lot_allocations_audit
after insert or update or delete on public.source_lot_allocations
for each row execute function public.audit_row_change();

commit;
