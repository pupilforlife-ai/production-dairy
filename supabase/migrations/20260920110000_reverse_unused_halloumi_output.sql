begin;

create or replace function public.reverse_unused_halloumi_output(
  requested_batch_id uuid,
  requested_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  target_lot public.intermediate_lots%rowtype;
  kilogram_id uuid;
  cleaned_reason text := nullif(trim(coalesce(requested_reason, '')), '');
begin
  if public.current_user_role() not in ('owner'::public.app_role, 'admin'::public.app_role) then
    raise exception 'Owner or admin access required';
  end if;
  if cleaned_reason is null then raise exception 'A correction reason is required'; end if;

  select * into target_batch from public.production_batches where id = requested_batch_id for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be reversed'; end if;

  select il.* into target_lot
  from public.production_batch_outputs pbo
  join public.intermediate_lots il on il.id = pbo.generated_intermediate_lot_id
  where pbo.batch_id = target_batch.id and pbo.output_type = 'primary'
  for update;
  if not found then raise exception 'No generated Halloumi stock lot was found'; end if;
  if target_lot.current_quantity <> target_lot.produced_quantity then
    raise exception 'Halloumi stock has already been consumed or transferred';
  end if;
  if exists (select 1 from public.transformation_inputs where source_intermediate_lot_id = target_lot.id)
     or exists (select 1 from public.packing_run_sources where intermediate_lot_id = target_lot.id) then
    raise exception 'Halloumi stock has downstream usage and cannot be reversed';
  end if;

  select id into kilogram_id from public.units_of_measure where code = 'kg';
  update public.intermediate_lots
  set current_quantity = 0, status = 'depleted'::public.intermediate_lot_status,
      updated_at = now(), updated_by = auth.uid()
  where id = target_lot.id;
  insert into public.intermediate_lot_movements (
    intermediate_lot_id, movement_type, quantity, uom_id, reference, occurred_at, created_by
  ) values (
    target_lot.id, 'correction'::public.intermediate_movement_type, target_lot.current_quantity,
    kilogram_id, 'Reversed unused Halloumi output: ' || cleaned_reason, now(), coalesce(auth.uid(), target_batch.created_by)
  );
  update public.production_batches
  set gross_output_quantity = null, output_uom_id = null, completed_at = null,
      updated_at = now(), updated_by = auth.uid()
  where id = target_batch.id;
end;
$$;

revoke all on function public.reverse_unused_halloumi_output(uuid, text) from public;
grant execute on function public.reverse_unused_halloumi_output(uuid, text) to authenticated;
commit;
