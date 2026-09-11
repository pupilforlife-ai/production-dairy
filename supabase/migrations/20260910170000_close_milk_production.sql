begin;

alter table public.source_lots
add column unaccounted_loss_quantity numeric,
add column closure_notes text,
add constraint source_lots_unaccounted_loss_nonnegative_check
  check (unaccounted_loss_quantity is null or unaccounted_loss_quantity >= 0);

comment on column public.source_lots.unaccounted_loss_quantity is
  'Balance recorded as unaccounted process loss or spillage when milk production is closed.';
comment on column public.source_lots.closure_notes is
  'Optional owner note recorded when milk production is closed.';

create or replace function public.prevent_locked_source_lot_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if old.locked_at is not null or old.status = 'closed'::public.source_lot_status then
    raise exception 'A closed milk production receipt cannot be edited';
  end if;
  return new;
end;
$$;

create trigger source_lots_00_prevent_locked_update
before update on public.source_lots
for each row execute function public.prevent_locked_source_lot_update();

create or replace function public.prevent_locked_production_shift_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if old.locked_at is not null then
    raise exception 'A closed production shift cannot be edited';
  end if;
  return new;
end;
$$;

create trigger production_shifts_00_prevent_locked_update
before update on public.production_shifts
for each row execute function public.prevent_locked_production_shift_update();

create or replace function public.prevent_locked_production_batch_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if old.locked_at is not null then
    raise exception 'A closed production round cannot be edited';
  end if;
  return new;
end;
$$;

create trigger production_batches_00_prevent_locked_update
before update on public.production_batches
for each row execute function public.prevent_locked_production_batch_update();

create or replace function public.require_open_source_lot_for_production()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  requested_lot_id uuid;
  lot_status public.source_lot_status;
  lot_locked_at timestamptz;
begin
  if tg_table_name = 'production_shifts' then
    requested_lot_id := new.source_lot_id;
  else
    requested_lot_id := new.parent_source_lot_id;
  end if;

  if requested_lot_id is null then return new; end if;

  select status, locked_at
  into lot_status, lot_locked_at
  from public.source_lots
  where id = requested_lot_id;

  if not found then raise exception 'Source milk receipt does not exist'; end if;
  if lot_status <> 'accepted'::public.source_lot_status or lot_locked_at is not null then
    raise exception 'New production cannot be added to a closed milk receipt';
  end if;
  return new;
end;
$$;

create trigger production_shifts_require_open_source_lot
before insert or update of source_lot_id on public.production_shifts
for each row execute function public.require_open_source_lot_for_production();

create trigger production_batches_require_open_source_lot
before insert or update of parent_source_lot_id on public.production_batches
for each row execute function public.require_open_source_lot_for_production();

create or replace function public.retry_production_round_ingredient_shortages(
  requested_batch_id uuid
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  batch_locked_at timestamptz;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;

  select locked_at into batch_locked_at
  from public.production_batches
  where id = requested_batch_id;

  if not found then raise exception 'Production round does not exist'; end if;
  if batch_locked_at is not null then
    raise exception 'Ingredient shortages cannot be retried for a closed production round';
  end if;

  perform public.issue_due_production_ingredients(requested_batch_id);
end;
$$;

create or replace function public.close_milk_production(
  requested_source_lot_id uuid,
  requested_closure_notes text default null
)
returns numeric
language plpgsql security definer set search_path = ''
as $$
declare
  target_lot public.source_lots%rowtype;
  allocated_quantity numeric;
  production_quantity numeric;
  transformation_quantity numeric;
  committed_quantity numeric;
  loss_quantity numeric;
  closure_time timestamptz := now();
begin
  if not public.is_owner() then
    raise exception 'Only the Owner can close milk production';
  end if;

  select * into target_lot
  from public.source_lots
  where id = requested_source_lot_id
  for update;

  if not found then raise exception 'Milk receipt does not exist'; end if;
  if target_lot.lot_type <> 'milk'::public.source_lot_type then
    raise exception 'Only a milk receipt can close milk production';
  end if;
  if target_lot.status = 'closed'::public.source_lot_status then
    return coalesce(target_lot.unaccounted_loss_quantity, 0);
  end if;
  if target_lot.status <> 'accepted'::public.source_lot_status
    or target_lot.locked_at is not null then
    raise exception 'Only accepted, open milk production can be closed';
  end if;

  select coalesce(sum(quantity), 0) into allocated_quantity
  from public.source_lot_allocations
  where source_lot_id = requested_source_lot_id;

  select coalesce(sum(actual_primary_input_quantity), 0) into production_quantity
  from public.production_batches
  where parent_source_lot_id = requested_source_lot_id
    and status <> 'cancelled'::public.production_status;

  select coalesce(sum(input.quantity), 0) into transformation_quantity
  from public.transformation_source_lot_inputs input
  join public.transformations transformation on transformation.id = input.transformation_id
  where input.source_lot_id = requested_source_lot_id
    and transformation.status = 'completed'::public.transformation_status;

  committed_quantity := greatest(
    allocated_quantity,
    production_quantity + transformation_quantity
  );
  loss_quantity := greatest(target_lot.received_quantity - committed_quantity, 0);

  update public.production_batches
  set locked_at = closure_time, locked_by = auth.uid()
  where parent_source_lot_id = requested_source_lot_id
    and locked_at is null;

  update public.production_shifts
  set
    status = case
      when status = 'open'::public.shift_status then 'completed'::public.shift_status
      else status
    end,
    ended_at = case
      when status = 'open'::public.shift_status then coalesce(ended_at, closure_time)
      else ended_at
    end,
    locked_at = closure_time,
    locked_by = auth.uid()
  where source_lot_id = requested_source_lot_id
    and locked_at is null;

  update public.source_lots
  set
    status = 'closed'::public.source_lot_status,
    unaccounted_loss_quantity = loss_quantity,
    closure_notes = nullif(trim(requested_closure_notes), ''),
    locked_at = closure_time,
    locked_by = auth.uid()
  where id = requested_source_lot_id;

  return loss_quantity;
end;
$$;

revoke all on function public.close_milk_production(uuid, text) from public, anon;
grant execute on function public.close_milk_production(uuid, text) to authenticated;

commit;
