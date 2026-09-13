begin;

create or replace function public.cancel_accidental_production_round(
  requested_batch_id uuid,
  requested_reason text
)
returns public.production_status
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  cleaned_reason text := nullif(trim(coalesce(requested_reason, '')), '');
begin
  if public.current_user_role() not in ('owner'::public.app_role, 'admin'::public.app_role) then
    raise exception 'Owner or admin access required';
  end if;
  if cleaned_reason is null then
    raise exception 'A correction reason is required';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;

  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be cancelled'; end if;
  if target_batch.status = 'cancelled'::public.production_status then
    return target_batch.status;
  end if;
  if target_batch.gross_output_quantity is not null then
    raise exception 'This round has production output and cannot be cancelled from the board';
  end if;
  if exists (
    select 1 from public.production_round_packing_entries
    where production_batch_id = target_batch.id
  ) then
    raise exception 'This round has packing entries and cannot be cancelled from the board';
  end if;
  if exists (
    select 1 from public.production_round_blocks
    where production_batch_id = target_batch.id
      and weight_kg is not null
  ) then
    raise exception 'This round has recorded block weights and cannot be cancelled from the board';
  end if;
  if exists (
    select 1 from public.production_round_cream_buckets
    where production_batch_id = target_batch.id
  ) then
    raise exception 'This round has cream buckets and cannot be cancelled from the board';
  end if;
  if exists (
    select 1 from public.transformations
    where source_batch_id = target_batch.id
      and status = 'completed'::public.transformation_status
  ) then
    raise exception 'This round has completed transformations and cannot be cancelled from the board';
  end if;

  update public.production_batches
  set
    status = 'cancelled'::public.production_status,
    completed_at = null,
    notes = concat_ws(
      E'\n',
      nullif(notes, ''),
      'Correction: cancelled accidental round — ' || cleaned_reason
    ),
    updated_at = now(),
    updated_by = auth.uid()
  where id = target_batch.id;

  insert into public.audit_events (
    entity_type, entity_id, action, actor_user_id, old_data, new_data, reason
  ) values (
    'production_batch',
    target_batch.id,
    'cancel_accidental_round',
    auth.uid(),
    to_jsonb(target_batch),
    jsonb_build_object('status', 'cancelled'),
    cleaned_reason
  );

  return 'cancelled'::public.production_status;
end;
$$;

revoke all on function public.cancel_accidental_production_round(uuid, text) from public;
grant execute on function public.cancel_accidental_production_round(uuid, text) to authenticated;

commit;
