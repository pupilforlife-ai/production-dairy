begin;

create or replace function public.void_production_round_cream_bucket(
  requested_bucket_id uuid,
  requested_reason text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_bucket public.production_round_cream_buckets%rowtype;
  target_lot public.intermediate_lots%rowtype;
  movement_count integer;
begin
  if public.current_user_role() not in ('owner'::public.app_role, 'admin'::public.app_role) then
    raise exception 'Only an owner or admin can void cream buckets';
  end if;
  if length(trim(coalesce(requested_reason, ''))) = 0 then
    raise exception 'A correction reason is required';
  end if;

  select * into target_bucket
  from public.production_round_cream_buckets
  where id = requested_bucket_id
  for update;
  if not found then raise exception 'Cream bucket does not exist'; end if;

  select * into target_lot
  from public.intermediate_lots
  where id = target_bucket.intermediate_lot_id
  for update;
  if not found then raise exception 'Recovered cream stock lot is missing'; end if;
  if target_lot.status <> 'available'::public.intermediate_lot_status
    or target_lot.current_quantity <> target_lot.produced_quantity then
    raise exception 'This cream bucket has already been used and cannot be voided here';
  end if;

  select count(*) into movement_count
  from public.intermediate_lot_movements movement
  where movement.intermediate_lot_id = target_lot.id
    and movement.id <> target_bucket.movement_id;
  if movement_count > 0 then
    raise exception 'This cream bucket has stock movements and cannot be voided here';
  end if;

  insert into public.corrections (
    entity_type, entity_id, field_or_measure, replacement_value, reason, created_by
  ) values (
    'production_round_cream_buckets',
    target_bucket.id,
    'void_duplicate_bucket',
    jsonb_build_object(
      'production_batch_id', target_bucket.production_batch_id,
      'bucket_number', target_bucket.bucket_number,
      'weight_kg', target_bucket.weight_kg,
      'intermediate_lot_id', target_bucket.intermediate_lot_id,
      'production_batch_output_id', target_bucket.production_batch_output_id,
      'movement_id', target_bucket.movement_id,
      'recorded_at', target_bucket.recorded_at
    ),
    trim(requested_reason),
    auth.uid()
  );

  delete from public.production_round_cream_buckets
  where id = target_bucket.id;

  delete from public.intermediate_lot_movements
  where id = target_bucket.movement_id;

  delete from public.production_batch_outputs
  where id = target_bucket.production_batch_output_id;

  delete from public.intermediate_lots
  where id = target_bucket.intermediate_lot_id;

  return target_bucket.id;
end;
$$;

revoke all on function public.void_production_round_cream_bucket(uuid, text)
from public, anon;
grant execute on function public.void_production_round_cream_bucket(uuid, text)
to authenticated;

commit;
