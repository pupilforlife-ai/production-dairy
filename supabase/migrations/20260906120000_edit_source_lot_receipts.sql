begin;

create or replace function public.update_source_lot_receipt(
  requested_source_lot_id uuid,
  requested_lot_type public.source_lot_type,
  requested_lot_code text,
  requested_invoice_number text,
  requested_received_from text,
  requested_received_at timestamptz,
  requested_received_quantity numeric,
  requested_status public.source_lot_status,
  requested_notes text default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target_lot public.source_lots%rowtype;
  allocated_quantity numeric;
  production_quantity numeric;
  transformation_quantity numeric;
  committed_quantity numeric;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;

  select * into target_lot
  from public.source_lots
  where id = requested_source_lot_id
  for update;

  if not found then raise exception 'Milk or cream receipt does not exist'; end if;
  if target_lot.locked_at is not null or target_lot.status = 'closed' then
    raise exception 'A closed receipt cannot be edited';
  end if;
  if length(trim(coalesce(requested_lot_code, ''))) = 0 then
    raise exception 'Lot or batch code is required';
  end if;
  if length(trim(coalesce(requested_invoice_number, ''))) = 0 then
    raise exception 'Invoice number is required';
  end if;
  if length(trim(coalesce(requested_received_from, ''))) = 0 then
    raise exception 'Received-from details are required';
  end if;
  if requested_received_at is null then raise exception 'Received date and time are required'; end if;
  if requested_received_quantity is null or requested_received_quantity <= 0 then
    raise exception 'Received quantity must be positive';
  end if;
  if requested_status not in (
    'accepted'::public.source_lot_status,
    'rejected'::public.source_lot_status
  ) then raise exception 'Receipt decision must be accepted or rejected'; end if;

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

  if requested_received_quantity < committed_quantity then
    raise exception 'Received quantity cannot be lower than % already allocated or consumed',
      committed_quantity;
  end if;
  if requested_lot_type <> target_lot.lot_type and committed_quantity > 0 then
    raise exception 'The material type cannot change after stock is allocated or consumed';
  end if;
  if requested_status = 'rejected'::public.source_lot_status and committed_quantity > 0 then
    raise exception 'A receipt already allocated or consumed cannot be rejected';
  end if;

  update public.source_lots
  set
    lot_type = requested_lot_type,
    lot_code = trim(requested_lot_code),
    invoice_number = trim(requested_invoice_number),
    received_from = trim(requested_received_from),
    received_at = requested_received_at,
    received_quantity = requested_received_quantity,
    status = requested_status,
    notes = nullif(trim(requested_notes), '')
  where id = requested_source_lot_id;
end;
$$;

revoke all on function public.update_source_lot_receipt(
  uuid, public.source_lot_type, text, text, text, timestamptz,
  numeric, public.source_lot_status, text
) from public;
grant execute on function public.update_source_lot_receipt(
  uuid, public.source_lot_type, text, text, text, timestamptz,
  numeric, public.source_lot_status, text
) to authenticated;

commit;
