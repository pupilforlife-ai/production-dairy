begin;

create or replace function public.add_halloumi_production_round(requested_shift_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_shift public.production_shifts%rowtype;
  source_lot public.source_lots%rowtype;
  halloumi_product_id uuid;
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

  select id into halloumi_product_id
  from public.products
  where code = 'RAW_HALLOUMI' and active;
  if halloumi_product_id is null then raise exception 'Raw halloumi product is not configured'; end if;

  select coalesce(max(round_number), 0) + 1 into next_round
  from public.production_batches
  where shift_id = requested_shift_id;

  internal_batch_code := to_char(
      source_lot.received_at at time zone 'Africa/Johannesburg',
      'DDMMYY'
    )
    || '-S' || lpad(target_shift.shift_number::text, 2, '0')
    || '-R' || lpad(next_round::text, 2, '0')
    || '-H';

  insert into public.production_batches (
    id, batch_code, parent_source_lot_id, shift_id, round_number,
    product_id, planned_input_quantity, actual_primary_input_quantity, input_uom_id,
    status, process_stage, process_stage_changed_at,
    started_at, created_by, updated_by
  ) values (
    generated_batch_id, internal_batch_code, target_shift.source_lot_id,
    target_shift.id, next_round, halloumi_product_id, 240, 240, source_lot.uom_id,
    'in_production', 'halloumi_milk_received', now(), now(), auth.uid(), auth.uid()
  );

  return generated_batch_id;
end;
$$;

create or replace function public.record_halloumi_raw_output(
  requested_batch_id uuid,
  requested_weight_kg numeric
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  raw_halloumi_id uuid;
  kilogram_id uuid;
  chiller_id uuid;
  generated_lot_id uuid;
  prior_location_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_weight_kg is null or requested_weight_kg <= 0 then
    raise exception 'Raw halloumi weight must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Halloumi round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.status = 'cancelled'::public.production_status then
    raise exception 'Cannot record output for a cancelled round';
  end if;

  select id into raw_halloumi_id from public.products where code = 'RAW_HALLOUMI';
  if target_batch.product_id <> raw_halloumi_id then
    raise exception 'Raw halloumi output can only be recorded for a halloumi round';
  end if;
  if target_batch.process_stage <> 'halloumi_raw_ready'::public.paneer_process_stage then
    raise exception 'Move the halloumi round to Raw Halloumi Ready before recording output';
  end if;

  select id into kilogram_id from public.units_of_measure where code = 'kg';
  select id into chiller_id from public.storage_locations where code = 'CHILLER' and active;
  if kilogram_id is null then raise exception 'Kilogram unit is not configured'; end if;
  if chiller_id is null then raise exception 'Chiller storage location is unavailable'; end if;

  update public.production_batches
  set
    gross_output_quantity = requested_weight_kg,
    output_uom_id = kilogram_id,
    completed_at = coalesce(completed_at, now()),
    status = 'ready_for_cutting'::public.production_status
  where id = target_batch.id;

  select il.id, il.storage_location_id
  into generated_lot_id, prior_location_id
  from public.production_batch_outputs output
  join public.intermediate_lots il on il.id = output.generated_intermediate_lot_id
  where output.batch_id = target_batch.id
    and output.output_type = 'primary'
  for update;

  update public.intermediate_lots
  set
    product_id = raw_halloumi_id,
    lot_code = target_batch.batch_code || '-RAW-H',
    display_label = 'Raw halloumi',
    storage_location_id = chiller_id,
    produced_at = coalesce(target_batch.completed_at, now()),
    updated_at = now(),
    updated_by = auth.uid()
  where id = generated_lot_id;

  update public.production_batch_outputs
  set
    product_id = raw_halloumi_id,
    destination_location_id = chiller_id
  where batch_id = target_batch.id
    and output_type = 'primary';

  if prior_location_id is distinct from chiller_id then
    insert into public.intermediate_lot_movements (
      intermediate_lot_id, movement_type, quantity, uom_id,
      from_location_id, to_location_id, reference, occurred_at, created_by
    ) values (
      generated_lot_id, 'transfer', requested_weight_kg, kilogram_id,
      prior_location_id, chiller_id, 'Raw halloumi to chiller', now(), auth.uid()
    );
  end if;

  return generated_lot_id;
end;
$$;

revoke all on function public.add_halloumi_production_round(uuid) from public, anon;
revoke all on function public.record_halloumi_raw_output(uuid, numeric) from public, anon;
grant execute on function public.add_halloumi_production_round(uuid) to authenticated;
grant execute on function public.record_halloumi_raw_output(uuid, numeric) to authenticated;

commit;
