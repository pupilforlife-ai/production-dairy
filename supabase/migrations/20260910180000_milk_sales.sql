begin;

create table public.source_lot_milk_sales (
  id uuid primary key default gen_random_uuid(),
  source_lot_id uuid not null references public.source_lots(id),
  sale_date date not null,
  customer text not null check (length(trim(customer)) > 0),
  quantity numeric not null check (quantity > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create index source_lot_milk_sales_lot_idx
on public.source_lot_milk_sales (source_lot_id, sale_date desc, created_at desc);

alter table public.source_lot_milk_sales enable row level security;

create policy source_lot_milk_sales_select
on public.source_lot_milk_sales for select to authenticated
using (public.current_user_role() is not null);

grant select on public.source_lot_milk_sales to authenticated;
revoke insert, update, delete on public.source_lot_milk_sales from anon, authenticated;

create trigger source_lot_milk_sales_audit
after insert or update or delete on public.source_lot_milk_sales
for each row execute function public.audit_row_change();

create or replace function public.record_source_lot_milk_sale(
  requested_source_lot_id uuid,
  requested_sale_date date,
  requested_customer text,
  requested_quantity numeric
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_lot public.source_lots%rowtype;
  allocated_quantity numeric;
  production_quantity numeric;
  transformation_quantity numeric;
  sold_quantity numeric;
  committed_quantity numeric;
  available_quantity numeric;
  new_sale_id uuid;
begin
  if not public.is_owner() then
    raise exception 'Only the Owner can record milk sales';
  end if;
  if requested_sale_date is null then raise exception 'Sale date is required'; end if;
  if length(trim(coalesce(requested_customer, ''))) = 0 then
    raise exception 'Customer is required';
  end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Milk sale quantity must be greater than zero';
  end if;

  select * into target_lot
  from public.source_lots
  where id = requested_source_lot_id
  for update;

  if not found then raise exception 'Milk receipt does not exist'; end if;
  if target_lot.lot_type <> 'milk'::public.source_lot_type then
    raise exception 'Milk sales can only be recorded against a milk receipt';
  end if;
  if target_lot.status <> 'accepted'::public.source_lot_status
    or target_lot.locked_at is not null then
    raise exception 'Milk cannot be sold from closed or rejected production';
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

  select coalesce(sum(quantity), 0) into sold_quantity
  from public.source_lot_milk_sales
  where source_lot_id = requested_source_lot_id;

  committed_quantity := greatest(
    allocated_quantity,
    production_quantity + transformation_quantity
  );
  available_quantity := greatest(
    target_lot.received_quantity - committed_quantity - sold_quantity,
    0
  );

  if requested_quantity > available_quantity then
    raise exception 'Milk sale cannot exceed % L currently available', available_quantity;
  end if;

  insert into public.source_lot_milk_sales (
    source_lot_id, sale_date, customer, quantity, created_by
  ) values (
    requested_source_lot_id,
    requested_sale_date,
    trim(requested_customer),
    requested_quantity,
    auth.uid()
  )
  returning id into new_sale_id;

  return new_sale_id;
end;
$$;

revoke all on function public.record_source_lot_milk_sale(uuid, date, text, numeric)
from public, anon;
grant execute on function public.record_source_lot_milk_sale(uuid, date, text, numeric)
to authenticated;

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
  sold_quantity numeric;
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

  select coalesce(sum(quantity), 0) into sold_quantity
  from public.source_lot_milk_sales
  where source_lot_id = requested_source_lot_id;

  committed_quantity := greatest(
    allocated_quantity,
    production_quantity + transformation_quantity
  );
  loss_quantity := greatest(
    target_lot.received_quantity - committed_quantity - sold_quantity,
    0
  );

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

commit;
