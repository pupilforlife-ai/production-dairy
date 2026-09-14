begin;

create or replace function public.spp_cutting_is_verified(requested_batch_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.transformations transformation
    where transformation.source_batch_id = requested_batch_id
      and transformation.transformation_type = 'cutting'
      and transformation.cut_type = 'SPP pieces'
      and transformation.status = 'completed'
  );
$$;

revoke all on function public.spp_cutting_is_verified(uuid) from public, anon;
grant execute on function public.spp_cutting_is_verified(uuid) to authenticated;

create or replace function public.keep_spp_cut_pending_until_verified()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.cut_format = 'spp'::public.paneer_cut_format
    and new.cut_completed_at is not null
    and not public.spp_cutting_is_verified(new.id) then
    new.cut_completed_at := null;
    new.status := 'ready_for_cutting'::public.production_status;
    new.cutting_allocation := 'SPP';
  end if;
  return new;
end;
$$;

drop trigger if exists production_batches_keep_spp_cut_pending
on public.production_batches;
create trigger production_batches_keep_spp_cut_pending
before update on public.production_batches
for each row execute function public.keep_spp_cut_pending_until_verified();

create or replace function public.verify_production_round_spp_cut(
  requested_batch_id uuid,
  requested_spp_weight_kg numeric,
  requested_occurred_at timestamptz default now(),
  requested_notes text default null
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  source_lot public.intermediate_lots%rowtype;
  freezer_location_id uuid;
  total_block_weight numeric;
  recorded_count integer;
  missing_count integer;
  pan111_weight numeric;
  transformation_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_spp_weight_kg is null or requested_spp_weight_kg <= 0 then
    raise exception 'Verified SPP weight must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.status = 'cancelled'::public.production_status then
    raise exception 'A cancelled round cannot be verified';
  end if;
  if target_batch.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
    raise exception 'The round must be ready for cutting first';
  end if;
  if target_batch.cut_format <> 'spp'::public.paneer_cut_format then
    raise exception 'Select SPP as the cut before verifying SPP weight';
  end if;
  if length(trim(coalesce(target_batch.cut_by, ''))) = 0 then
    raise exception 'Cut by is required before verifying SPP weight';
  end if;
  if exists (
    select 1 from public.production_round_packing_entries
    where production_batch_id = target_batch.id
  ) then raise exception 'SPP cut cannot change after packing is recorded'; end if;
  if public.spp_cutting_is_verified(target_batch.id) then
    raise exception 'SPP cut has already been verified for this round';
  end if;

  select count(*), count(*) filter (where weight_kg is null), coalesce(sum(weight_kg), 0)
  into recorded_count, missing_count, total_block_weight
  from public.production_round_blocks
  where production_batch_id = target_batch.id;

  if target_batch.pressed_block_count is null
    or recorded_count <> target_batch.pressed_block_count
    or missing_count > 0 then
    raise exception 'Record the weight of every pressed block before verifying SPP weight';
  end if;
  if requested_spp_weight_kg > total_block_weight then
    raise exception 'Verified SPP weight cannot exceed the total block weight';
  end if;

  pan111_weight := total_block_weight - requested_spp_weight_kg;

  select id into freezer_location_id
  from public.storage_locations
  where code = 'INTERMEDIATE_FREEZER' and active;
  if freezer_location_id is null then
    raise exception 'Intermediate Freezer is not configured';
  end if;

  if target_batch.gross_output_quantity is distinct from total_block_weight then
    update public.production_batches
    set gross_output_quantity = total_block_weight,
        output_uom_id = coalesce(output_uom_id, (
          select id from public.units_of_measure where code = 'kg'
        ))
    where id = target_batch.id;
  end if;

  select * into source_lot
  from public.intermediate_lots
  where source_batch_id = target_batch.id
    and source_transformation_id is null
    and current_quantity > 0
  order by produced_at, id
  limit 1
  for update;
  if not found then raise exception 'Uncut paneer stock is not available for this round'; end if;
  if source_lot.current_quantity < total_block_weight then
    raise exception 'Uncut paneer stock is lower than the total block weight';
  end if;

  transformation_id := public.record_cutting_transaction(
    source_lot.id,
    total_block_weight,
    coalesce(requested_occurred_at, now()),
    target_batch.cut_by,
    'SPP pieces',
    case when pan111_weight > 0 then
      jsonb_build_array(
        jsonb_build_object(
          'kind', 'primary',
          'label', 'Verified SPP paneer',
          'quantity', requested_spp_weight_kg,
          'destination_location_id', freezer_location_id
        ),
        jsonb_build_object(
          'kind', 'pan111',
          'label', 'PAN111',
          'quantity', pan111_weight,
          'destination_location_id', freezer_location_id
        )
      )
    else
      jsonb_build_array(
        jsonb_build_object(
          'kind', 'primary',
          'label', 'Verified SPP paneer',
          'quantity', requested_spp_weight_kg,
          'destination_location_id', freezer_location_id
        )
      )
    end,
    0,
    null,
    nullif(trim(coalesce(requested_notes, '')), '')
  );

  update public.production_batches
  set cut_completed_at = coalesce(requested_occurred_at, now()),
      status = 'cut'::public.production_status,
      cutting_allocation = 'SPP'
  where id = target_batch.id;

  return jsonb_build_object(
    'id', target_batch.id,
    'gross_output_quantity', total_block_weight,
    'cut_by', target_batch.cut_by,
    'cut_format', 'spp',
    'cut_completed_at', coalesce(requested_occurred_at, now()),
    'cutting_allocation', 'SPP',
    'status', 'cut',
    'verified_spp_weight_kg', requested_spp_weight_kg,
    'pan111_weight_kg', pan111_weight,
    'transformation_id', transformation_id
  );
end;
$$;

revoke all on function public.verify_production_round_spp_cut(
  uuid, numeric, timestamptz, text
) from public, anon;
grant execute on function public.verify_production_round_spp_cut(
  uuid, numeric, timestamptz, text
) to authenticated;

commit;
