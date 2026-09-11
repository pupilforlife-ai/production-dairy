begin;

-- Existing live-board rounds predate milk-quantity capture. Give each eligible
-- round the current 500 L standard without exceeding its source receipt.
with lot_capacity as (
  select
    lot.id as source_lot_id,
    lot.received_quantity
      - coalesce(sum(batch.actual_primary_input_quantity)
          filter (where batch.status <> 'cancelled'::public.production_status), 0) as available_quantity
  from public.source_lots lot
  left join public.production_batches batch
    on batch.parent_source_lot_id = lot.id
  where lot.lot_type = 'milk'::public.source_lot_type
  group by lot.id, lot.received_quantity
), eligible_rounds as (
  select
    batch.id,
    lot.uom_id,
    row_number() over (
      partition by batch.parent_source_lot_id
      order by batch.created_at, batch.round_number, batch.id
    ) as allocation_number,
    capacity.available_quantity
  from public.production_batches batch
  join public.source_lots lot on lot.id = batch.parent_source_lot_id
  join lot_capacity capacity on capacity.source_lot_id = batch.parent_source_lot_id
  where batch.actual_primary_input_quantity is null
    and batch.status <> 'cancelled'::public.production_status
)
update public.production_batches batch
set
  planned_input_quantity = coalesce(batch.planned_input_quantity, 500),
  actual_primary_input_quantity = 500,
  input_uom_id = eligible.uom_id
from eligible_rounds eligible
where batch.id = eligible.id
  and eligible.allocation_number * 500 <= eligible.available_quantity;

create or replace function public.add_live_production_round(requested_shift_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_shift public.production_shifts%rowtype;
  source_lot public.source_lots%rowtype;
  default_product_id uuid;
  next_round integer;
  generated_batch_id uuid := gen_random_uuid();
  internal_batch_code text;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;

  select * into target_shift
  from public.production_shifts
  where id = requested_shift_id
  for update;
  if not found then raise exception 'Production shift does not exist'; end if;
  if target_shift.status <> 'open'::public.shift_status or target_shift.locked_at is not null then
    raise exception 'Rounds can only be added to an open shift';
  end if;

  select * into source_lot
  from public.source_lots
  where id = target_shift.source_lot_id;
  if source_lot.status <> 'accepted'::public.source_lot_status then
    raise exception 'The shift milk lot is not accepted';
  end if;

  select id into default_product_id
  from public.products
  where code = 'MALAI_PANEER' and active;
  if default_product_id is null then raise exception 'D paneer product is not configured'; end if;

  select coalesce(max(round_number), 0) + 1 into next_round
  from public.production_batches
  where shift_id = requested_shift_id;

  internal_batch_code := to_char(
      source_lot.received_at at time zone 'Africa/Johannesburg',
      'DDMMYY'
    )
    || '-S' || lpad(target_shift.shift_number::text, 2, '0')
    || '-R' || lpad(next_round::text, 2, '0')
    || '-' || upper(substr(replace(source_lot.id::text, '-', ''), 1, 4));

  insert into public.production_batches (
    id, batch_code, parent_source_lot_id, shift_id, round_number,
    product_id, planned_input_quantity, actual_primary_input_quantity, input_uom_id,
    status, process_stage, process_stage_changed_at,
    started_at, created_by, updated_by
  ) values (
    generated_batch_id, internal_batch_code, target_shift.source_lot_id,
    target_shift.id, next_round, default_product_id, 500, 500, source_lot.uom_id,
    'in_production', 'vat_1', now(), now(), auth.uid(), auth.uid()
  );

  return generated_batch_id;
end;
$$;

create or replace function public.update_production_round_milk_quantity(
  requested_batch_id uuid,
  requested_quantity numeric
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  source_uom_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Milk quantity must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.status = 'cancelled'::public.production_status then
    raise exception 'Milk quantity cannot be changed on a cancelled round';
  end if;

  select uom_id into source_uom_id
  from public.source_lots
  where id = target_batch.parent_source_lot_id;
  if source_uom_id is null then raise exception 'The round source milk lot is unavailable'; end if;

  update public.production_batches
  set
    planned_input_quantity = coalesce(planned_input_quantity, 500),
    actual_primary_input_quantity = requested_quantity,
    input_uom_id = source_uom_id
  where id = target_batch.id;

  return jsonb_build_object(
    'id', target_batch.id,
    'planned_input_quantity', coalesce(target_batch.planned_input_quantity, 500),
    'actual_primary_input_quantity', requested_quantity
  );
end;
$$;

revoke all on function public.update_production_round_milk_quantity(uuid, numeric)
from public, anon;
grant execute on function public.update_production_round_milk_quantity(uuid, numeric)
to authenticated;

commit;
