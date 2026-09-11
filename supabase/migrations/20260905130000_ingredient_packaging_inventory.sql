begin;

create type public.inventory_item_type as enum ('ingredient', 'packaging');
create type public.inventory_lot_status as enum ('active', 'depleted', 'quarantined');
create type public.inventory_movement_type as enum (
  'receive',
  'transfer',
  'consume',
  'adjustment_in',
  'adjustment_out'
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  item_type public.inventory_item_type not null,
  ingredient_id uuid unique references public.ingredients(id),
  code text not null unique,
  name text not null unique,
  default_uom_id uuid not null references public.units_of_measure(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  check (item_type = 'ingredient' or ingredient_id is null)
);

create table public.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items(id),
  lot_code text not null,
  supplier_id uuid references public.suppliers(id),
  received_at timestamptz not null,
  received_quantity numeric not null check (received_quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  expiry_date date,
  status public.inventory_lot_status not null default 'active',
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  unique (inventory_item_id, lot_code)
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items(id),
  inventory_lot_id uuid not null references public.inventory_lots(id),
  source_location_id uuid references public.storage_locations(id),
  destination_location_id uuid references public.storage_locations(id),
  movement_type public.inventory_movement_type not null,
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  production_batch_id uuid references public.production_batches(id),
  packing_run_id uuid references public.packing_runs(id),
  reason text,
  notes text,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  check (source_location_id is not null or destination_location_id is not null),
  check (source_location_id is distinct from destination_location_id),
  check (
    (movement_type = 'receive' and source_location_id is null and destination_location_id is not null)
    or (movement_type = 'transfer' and source_location_id is not null and destination_location_id is not null)
    or (movement_type = 'consume' and source_location_id is not null and destination_location_id is null)
    or (movement_type = 'adjustment_in' and source_location_id is null and destination_location_id is not null)
    or (movement_type = 'adjustment_out' and source_location_id is not null and destination_location_id is null)
  ),
  check (
    movement_type not in ('adjustment_in', 'adjustment_out')
    or length(trim(reason)) > 0
  ),
  check (num_nonnulls(production_batch_id, packing_run_id) <= 1)
);

create index inventory_items_type_idx on public.inventory_items (item_type, active);
create index inventory_lots_item_idx on public.inventory_lots (inventory_item_id);
create index inventory_lots_received_idx on public.inventory_lots (received_at desc);
create index inventory_movements_lot_idx
on public.inventory_movements (inventory_lot_id, occurred_at desc);
create index inventory_movements_item_idx
on public.inventory_movements (inventory_item_id, occurred_at desc);
create index inventory_movements_source_idx
on public.inventory_movements (source_location_id);
create index inventory_movements_destination_idx
on public.inventory_movements (destination_location_id);
create index inventory_movements_batch_idx
on public.inventory_movements (production_batch_id);
create index inventory_movements_packing_idx
on public.inventory_movements (packing_run_id);

insert into public.inventory_items (
  item_type, ingredient_id, code, name, default_uom_id, created_by, updated_by
)
select
  'ingredient', ingredient.id, ingredient.code, ingredient.name,
  ingredient.default_uom_id, ingredient.created_by, ingredient.updated_by
from public.ingredients ingredient
on conflict (code) do nothing;

alter table public.inventory_items enable row level security;
alter table public.inventory_lots enable row level security;
alter table public.inventory_movements enable row level security;

create policy inventory_items_authenticated_select on public.inventory_items
for select to authenticated using (public.current_user_role() is not null);
create policy inventory_lots_authenticated_select on public.inventory_lots
for select to authenticated using (public.current_user_role() is not null);
create policy inventory_movements_authenticated_select on public.inventory_movements
for select to authenticated using (public.current_user_role() is not null);

grant select on public.inventory_items, public.inventory_lots, public.inventory_movements
to authenticated;
revoke insert, update, delete
on public.inventory_items, public.inventory_lots, public.inventory_movements
from anon, authenticated;

create or replace view public.inventory_balances
with (security_invoker = true)
as
with position_rows as (
  select
    movement.inventory_item_id,
    movement.inventory_lot_id,
    movement.destination_location_id as storage_location_id,
    movement.quantity,
    movement.uom_id
  from public.inventory_movements movement
  where movement.destination_location_id is not null
  union all
  select
    movement.inventory_item_id,
    movement.inventory_lot_id,
    movement.source_location_id as storage_location_id,
    -movement.quantity,
    movement.uom_id
  from public.inventory_movements movement
  where movement.source_location_id is not null
)
select
  item.id as inventory_item_id,
  item.item_type,
  item.code as item_code,
  item.name as item_name,
  lot.id as inventory_lot_id,
  lot.lot_code,
  lot.received_at,
  lot.expiry_date,
  location.id as storage_location_id,
  location.code as location_code,
  location.name as location_name,
  uom.id as uom_id,
  uom.code as uom_code,
  sum(position.quantity) as current_quantity
from position_rows position
join public.inventory_items item on item.id = position.inventory_item_id
join public.inventory_lots lot on lot.id = position.inventory_lot_id
join public.storage_locations location on location.id = position.storage_location_id
join public.units_of_measure uom on uom.id = position.uom_id
group by
  item.id, item.item_type, item.code, item.name,
  lot.id, lot.lot_code, lot.received_at, lot.expiry_date,
  location.id, location.code, location.name, uom.id, uom.code
having sum(position.quantity) <> 0;

revoke all on public.inventory_balances from anon;
grant select on public.inventory_balances to authenticated;

create or replace function public.current_inventory_balance(
  requested_lot_id uuid,
  requested_location_id uuid
)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(
    case
      when destination_location_id = requested_location_id then quantity
      when source_location_id = requested_location_id then -quantity
      else 0
    end
  ), 0)
  from public.inventory_movements
  where inventory_lot_id = requested_lot_id
    and (
      destination_location_id = requested_location_id
      or source_location_id = requested_location_id
    );
$$;

revoke all on function public.current_inventory_balance(uuid, uuid) from public;

create or replace function public.create_inventory_item(
  requested_item_type public.inventory_item_type,
  requested_code text,
  requested_name text,
  requested_uom_id uuid
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_item_id uuid;
  new_ingredient_id uuid;
begin
  if not public.is_owner() then raise exception 'Only an owner can create inventory items'; end if;
  if length(trim(coalesce(requested_code, ''))) = 0
    or length(trim(coalesce(requested_name, ''))) = 0 then
    raise exception 'Item code and name are required';
  end if;
  if not exists (
    select 1 from public.units_of_measure where id = requested_uom_id and active
  ) then raise exception 'Unit of measure is unavailable'; end if;

  if requested_item_type = 'ingredient' then
    insert into public.ingredients (
      code, name, default_uom_id, created_by, updated_by
    ) values (
      upper(trim(requested_code)), trim(requested_name), requested_uom_id,
      auth.uid(), auth.uid()
    ) returning id into new_ingredient_id;
  end if;

  insert into public.inventory_items (
    item_type, ingredient_id, code, name, default_uom_id, created_by, updated_by
  ) values (
    requested_item_type, new_ingredient_id, upper(trim(requested_code)),
    trim(requested_name), requested_uom_id, auth.uid(), auth.uid()
  ) returning id into new_item_id;
  return new_item_id;
end;
$$;

create or replace function public.receive_inventory(
  requested_item_id uuid,
  requested_lot_code text,
  requested_quantity numeric,
  requested_destination_location_id uuid,
  requested_received_at timestamptz,
  requested_expiry_date date default null,
  requested_notes text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  item_uom_id uuid;
  new_lot_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Received quantity must be greater than zero';
  end if;
  if length(trim(coalesce(requested_lot_code, ''))) = 0 then
    raise exception 'Supplier lot code is required';
  end if;
  select default_uom_id into item_uom_id
  from public.inventory_items
  where id = requested_item_id and active;
  if not found then raise exception 'Inventory item is unavailable'; end if;
  if not exists (
    select 1 from public.storage_locations
    where id = requested_destination_location_id and active
  ) then raise exception 'Receiving location is unavailable'; end if;

  insert into public.inventory_lots (
    inventory_item_id, lot_code, received_at, received_quantity,
    uom_id, expiry_date, status, notes, created_by, updated_by
  ) values (
    requested_item_id, trim(requested_lot_code), requested_received_at,
    requested_quantity, item_uom_id, requested_expiry_date, 'active',
    nullif(trim(requested_notes), ''), auth.uid(), auth.uid()
  ) returning id into new_lot_id;

  insert into public.inventory_movements (
    inventory_item_id, inventory_lot_id, destination_location_id,
    movement_type, quantity, uom_id, notes, occurred_at, created_by
  ) values (
    requested_item_id, new_lot_id, requested_destination_location_id,
    'receive', requested_quantity, item_uom_id,
    nullif(trim(requested_notes), ''), requested_received_at, auth.uid()
  );

  return new_lot_id;
end;
$$;

create or replace function public.transfer_inventory(
  requested_lot_id uuid,
  requested_source_location_id uuid,
  requested_destination_location_id uuid,
  requested_quantity numeric,
  requested_occurred_at timestamptz default now(),
  requested_notes text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  inventory_lot public.inventory_lots%rowtype;
  available_quantity numeric;
  movement_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Transfer quantity must be greater than zero';
  end if;
  if requested_source_location_id = requested_destination_location_id then
    raise exception 'Choose a different destination location';
  end if;

  select * into inventory_lot
  from public.inventory_lots
  where id = requested_lot_id
  for update;
  if not found then raise exception 'Inventory lot does not exist'; end if;
  if inventory_lot.status <> 'active' then raise exception 'Inventory lot is not available'; end if;
  if not exists (
    select 1 from public.storage_locations
    where id = requested_destination_location_id and active
  ) then raise exception 'Destination location is unavailable'; end if;

  available_quantity := public.current_inventory_balance(
    requested_lot_id, requested_source_location_id
  );
  if requested_quantity > available_quantity then
    raise exception 'Transfer quantity cannot exceed available stock';
  end if;

  insert into public.inventory_movements (
    inventory_item_id, inventory_lot_id, source_location_id,
    destination_location_id, movement_type, quantity, uom_id,
    notes, occurred_at, created_by
  ) values (
    inventory_lot.inventory_item_id, inventory_lot.id,
    requested_source_location_id, requested_destination_location_id,
    'transfer', requested_quantity, inventory_lot.uom_id,
    nullif(trim(requested_notes), ''), requested_occurred_at, auth.uid()
  ) returning id into movement_id;
  return movement_id;
end;
$$;

create or replace function public.consume_inventory(
  requested_lot_id uuid,
  requested_source_location_id uuid,
  requested_quantity numeric,
  requested_production_batch_id uuid default null,
  requested_packing_run_id uuid default null,
  requested_occurred_at timestamptz default now(),
  requested_notes text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  inventory_lot public.inventory_lots%rowtype;
  available_quantity numeric;
  movement_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Consumption quantity must be greater than zero';
  end if;
  if num_nonnulls(requested_production_batch_id, requested_packing_run_id) > 1 then
    raise exception 'Choose either a production batch or a packing run reference';
  end if;

  select * into inventory_lot
  from public.inventory_lots
  where id = requested_lot_id
  for update;
  if not found then raise exception 'Inventory lot does not exist'; end if;
  if inventory_lot.status <> 'active' then raise exception 'Inventory lot is not available'; end if;

  available_quantity := public.current_inventory_balance(
    requested_lot_id, requested_source_location_id
  );
  if requested_quantity > available_quantity then
    raise exception 'Consumption quantity cannot exceed available stock';
  end if;

  insert into public.inventory_movements (
    inventory_item_id, inventory_lot_id, source_location_id,
    movement_type, quantity, uom_id, production_batch_id,
    packing_run_id, notes, occurred_at, created_by
  ) values (
    inventory_lot.inventory_item_id, inventory_lot.id,
    requested_source_location_id, 'consume', requested_quantity,
    inventory_lot.uom_id, requested_production_batch_id,
    requested_packing_run_id, nullif(trim(requested_notes), ''),
    requested_occurred_at, auth.uid()
  ) returning id into movement_id;
  return movement_id;
end;
$$;

create or replace function public.adjust_inventory_stocktake(
  requested_lot_id uuid,
  requested_location_id uuid,
  requested_adjustment_quantity numeric,
  requested_reason text,
  requested_occurred_at timestamptz default now()
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  inventory_lot public.inventory_lots%rowtype;
  available_quantity numeric;
  movement_id uuid;
begin
  if not public.is_owner() then raise exception 'Only an owner can adjust stocktake'; end if;
  if requested_adjustment_quantity is null or requested_adjustment_quantity = 0 then
    raise exception 'Adjustment quantity cannot be zero';
  end if;
  if length(trim(coalesce(requested_reason, ''))) = 0 then
    raise exception 'An adjustment reason is required';
  end if;

  select * into inventory_lot
  from public.inventory_lots
  where id = requested_lot_id
  for update;
  if not found then raise exception 'Inventory lot does not exist'; end if;
  available_quantity := public.current_inventory_balance(
    requested_lot_id, requested_location_id
  );
  if requested_adjustment_quantity < 0
    and abs(requested_adjustment_quantity) > available_quantity then
    raise exception 'Negative adjustment cannot exceed available stock';
  end if;

  insert into public.inventory_movements (
    inventory_item_id, inventory_lot_id, source_location_id,
    destination_location_id, movement_type, quantity, uom_id,
    reason, occurred_at, created_by
  ) values (
    inventory_lot.inventory_item_id, inventory_lot.id,
    case when requested_adjustment_quantity < 0 then requested_location_id else null end,
    case when requested_adjustment_quantity > 0 then requested_location_id else null end,
    case when requested_adjustment_quantity > 0
      then 'adjustment_in'::public.inventory_movement_type
      else 'adjustment_out'::public.inventory_movement_type end,
    abs(requested_adjustment_quantity), inventory_lot.uom_id,
    trim(requested_reason), requested_occurred_at, auth.uid()
  ) returning id into movement_id;
  return movement_id;
end;
$$;

create trigger inventory_items_set_update_metadata
before update on public.inventory_items
for each row execute function public.set_profile_update_metadata();
create trigger inventory_lots_set_update_metadata
before update on public.inventory_lots
for each row execute function public.set_profile_update_metadata();

create trigger inventory_items_audit
after insert or update or delete on public.inventory_items
for each row execute function public.audit_row_change();
create trigger inventory_lots_audit
after insert or update or delete on public.inventory_lots
for each row execute function public.audit_row_change();
create trigger inventory_movements_audit
after insert or update or delete on public.inventory_movements
for each row execute function public.audit_row_change();

revoke all on function public.create_inventory_item(
  public.inventory_item_type, text, text, uuid
) from public;
grant execute on function public.create_inventory_item(
  public.inventory_item_type, text, text, uuid
) to authenticated;

revoke all on function public.receive_inventory(
  uuid, text, numeric, uuid, timestamptz, date, text
) from public;
grant execute on function public.receive_inventory(
  uuid, text, numeric, uuid, timestamptz, date, text
) to authenticated;

revoke all on function public.transfer_inventory(
  uuid, uuid, uuid, numeric, timestamptz, text
) from public;
grant execute on function public.transfer_inventory(
  uuid, uuid, uuid, numeric, timestamptz, text
) to authenticated;

revoke all on function public.consume_inventory(
  uuid, uuid, numeric, uuid, uuid, timestamptz, text
) from public;
grant execute on function public.consume_inventory(
  uuid, uuid, numeric, uuid, uuid, timestamptz, text
) to authenticated;

revoke all on function public.adjust_inventory_stocktake(
  uuid, uuid, numeric, text, timestamptz
) from public;
grant execute on function public.adjust_inventory_stocktake(
  uuid, uuid, numeric, text, timestamptz
) to authenticated;

commit;
