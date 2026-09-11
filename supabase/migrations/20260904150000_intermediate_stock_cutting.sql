begin;

create type public.intermediate_lot_status as enum (
  'available',
  'reserved',
  'depleted',
  'quarantined'
);
create type public.transformation_status as enum ('completed', 'cancelled');
create type public.intermediate_movement_type as enum (
  'production_output',
  'transformation_input',
  'transformation_output',
  'transfer',
  'correction'
);

insert into public.products (
  family_id, code, name, product_type, variant, weight_mode
) values
  (
    (select id from public.product_families where code = 'PANEER'),
    'PAN111',
    'PAN111 Recovered Paneer',
    'intermediate',
    'PAN111',
    'variable'
  ),
  (
    (select id from public.product_families where code = 'CREAM_INTERMEDIATES'),
    'RECOVERED_CREAM',
    'Recovered Cream',
    'intermediate',
    null,
    'variable'
  )
on conflict (code) do nothing;

create table public.transformations (
  id uuid primary key default gen_random_uuid(),
  transformation_type text not null check (
    transformation_type in ('cutting', 'blending', 'filling', 'coating', 'frying')
  ),
  source_batch_id uuid references public.production_batches(id),
  occurred_at timestamptz not null,
  performed_by text not null check (length(trim(performed_by)) > 0),
  cut_type text,
  source_quantity numeric not null check (source_quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  loss_quantity numeric not null default 0 check (loss_quantity >= 0),
  loss_reason text,
  status public.transformation_status not null default 'completed',
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  check (loss_quantity = 0 or length(trim(loss_reason)) > 0)
);

create table public.intermediate_lots (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  source_batch_id uuid references public.production_batches(id),
  source_transformation_id uuid references public.transformations(id),
  parent_intermediate_lot_id uuid references public.intermediate_lots(id),
  lot_code text not null unique,
  display_label text,
  produced_quantity numeric not null check (produced_quantity >= 0),
  current_quantity numeric not null check (
    current_quantity >= 0 and current_quantity <= produced_quantity
  ),
  uom_id uuid not null references public.units_of_measure(id),
  storage_location_id uuid not null references public.storage_locations(id),
  status public.intermediate_lot_status not null default 'available',
  produced_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  check ((current_quantity = 0 and status = 'depleted') or current_quantity > 0)
);

create table public.production_batch_outputs (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.production_batches(id),
  product_id uuid not null references public.products(id),
  quantity numeric not null check (quantity >= 0),
  uom_id uuid not null references public.units_of_measure(id),
  output_type text not null check (
    output_type in ('primary', 'coproduct', 'recovered', 'waste_candidate')
  ),
  destination_location_id uuid references public.storage_locations(id),
  generated_intermediate_lot_id uuid references public.intermediate_lots(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create unique index production_batch_primary_output_unique_idx
on public.production_batch_outputs (batch_id)
where output_type = 'primary';

create table public.transformation_inputs (
  id uuid primary key default gen_random_uuid(),
  transformation_id uuid not null references public.transformations(id),
  source_intermediate_lot_id uuid not null references public.intermediate_lots(id),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create table public.transformation_outputs (
  id uuid primary key default gen_random_uuid(),
  transformation_id uuid not null references public.transformations(id),
  product_id uuid not null references public.products(id),
  output_kind text not null check (output_kind in ('primary', 'pan111', 'coproduct')),
  output_label text not null check (length(trim(output_label)) > 0),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  destination_location_id uuid not null references public.storage_locations(id),
  generated_intermediate_lot_id uuid not null references public.intermediate_lots(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create table public.intermediate_lot_movements (
  id uuid primary key default gen_random_uuid(),
  intermediate_lot_id uuid not null references public.intermediate_lots(id),
  movement_type public.intermediate_movement_type not null,
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  from_location_id uuid references public.storage_locations(id),
  to_location_id uuid references public.storage_locations(id),
  transformation_id uuid references public.transformations(id),
  reference text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create index transformations_source_batch_idx on public.transformations (source_batch_id);
create index transformations_occurred_at_idx on public.transformations (occurred_at desc);
create index intermediate_lots_product_idx on public.intermediate_lots (product_id);
create index intermediate_lots_source_batch_idx on public.intermediate_lots (source_batch_id);
create index intermediate_lots_source_transformation_idx
on public.intermediate_lots (source_transformation_id);
create index intermediate_lots_location_idx on public.intermediate_lots (storage_location_id);
create index intermediate_lots_fifo_idx
on public.intermediate_lots (status, produced_at, current_quantity);
create index production_batch_outputs_batch_idx on public.production_batch_outputs (batch_id);
create index transformation_inputs_transformation_idx
on public.transformation_inputs (transformation_id);
create index transformation_inputs_lot_idx
on public.transformation_inputs (source_intermediate_lot_id);
create index transformation_outputs_transformation_idx
on public.transformation_outputs (transformation_id);
create index intermediate_lot_movements_lot_idx
on public.intermediate_lot_movements (intermediate_lot_id, occurred_at desc);

create or replace function public.sync_primary_intermediate_output()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  existing_lot_id uuid;
  existing_produced numeric;
  existing_current numeric;
  consumed_quantity numeric;
  production_location_id uuid;
begin
  if new.gross_output_quantity is null then return new; end if;

  select id into production_location_id
  from public.storage_locations
  where code = 'PRODUCTION';
  if production_location_id is null then
    raise exception 'Production storage location is not configured';
  end if;

  select il.id, il.produced_quantity, il.current_quantity
  into existing_lot_id, existing_produced, existing_current
  from public.production_batch_outputs pbo
  join public.intermediate_lots il on il.id = pbo.generated_intermediate_lot_id
  where pbo.batch_id = new.id
    and pbo.output_type = 'primary'
  for update;

  if existing_lot_id is null then
    insert into public.intermediate_lots (
      product_id, source_batch_id, lot_code, display_label,
      produced_quantity, current_quantity, uom_id, storage_location_id,
      status, produced_at, created_by, updated_by
    ) values (
      new.product_id, new.id, new.batch_code || '-UNCUT', 'Uncut production output',
      new.gross_output_quantity, new.gross_output_quantity, new.output_uom_id,
      production_location_id,
      case when new.gross_output_quantity = 0
        then 'depleted'::public.intermediate_lot_status
        else 'available'::public.intermediate_lot_status end,
      coalesce(new.completed_at, new.started_at, new.created_at),
      new.created_by, auth.uid()
    )
    returning id into existing_lot_id;

    insert into public.production_batch_outputs (
      batch_id, product_id, quantity, uom_id, output_type,
      destination_location_id, generated_intermediate_lot_id, created_by
    ) values (
      new.id, new.product_id, new.gross_output_quantity, new.output_uom_id,
      'primary', production_location_id, existing_lot_id, new.created_by
    );

    if new.gross_output_quantity > 0 then
      insert into public.intermediate_lot_movements (
        intermediate_lot_id, movement_type, quantity, uom_id,
        to_location_id, reference, occurred_at, created_by
      ) values (
        existing_lot_id, 'production_output', new.gross_output_quantity,
        new.output_uom_id, production_location_id, new.batch_code,
        coalesce(new.completed_at, new.started_at, new.created_at), new.created_by
      );
    end if;
  else
    consumed_quantity := existing_produced - existing_current;
    if new.gross_output_quantity < consumed_quantity then
      raise exception 'Gross output cannot be lower than quantity already consumed';
    end if;

    update public.intermediate_lots
    set produced_quantity = new.gross_output_quantity,
        current_quantity = new.gross_output_quantity - consumed_quantity,
        status = case when new.gross_output_quantity - consumed_quantity = 0
          then 'depleted'::public.intermediate_lot_status
          else 'available'::public.intermediate_lot_status end,
        updated_at = now(),
        updated_by = auth.uid()
    where id = existing_lot_id;

    update public.production_batch_outputs
    set quantity = new.gross_output_quantity,
        uom_id = new.output_uom_id
    where batch_id = new.id and output_type = 'primary';
  end if;
  return new;
end;
$$;

create trigger production_batches_sync_primary_output
after insert or update of gross_output_quantity, output_uom_id
on public.production_batches
for each row execute function public.sync_primary_intermediate_output();

update public.production_batches
set gross_output_quantity = gross_output_quantity
where gross_output_quantity is not null;

create or replace function public.prevent_paneer_cutting_skip()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  is_paneer boolean;
  has_cutting boolean;
begin
  if new.status = old.status then return new; end if;
  if not (
    new.status = any(array[
      'freezing',
      'frozen_ready_for_packing',
      'part_packed',
      'packed',
      'ready_for_handover',
      'handed_over'
    ]::public.production_status[])
  ) then return new; end if;

  select exists (
    select 1
    from public.products p
    join public.product_families f on f.id = p.family_id
    where p.id = new.product_id and f.code = 'PANEER'
  ) into is_paneer;

  if not is_paneer then return new; end if;

  select exists (
    select 1 from public.transformations
    where source_batch_id = new.id
      and transformation_type = 'cutting'
      and status = 'completed'
  ) into has_cutting;

  if not has_cutting then
    raise exception 'Paneer must be cut or recorded as a fresh-pack allocation before freezing or packing';
  end if;
  return new;
end;
$$;

create trigger production_batches_prevent_cutting_skip
before update of status on public.production_batches
for each row execute function public.prevent_paneer_cutting_skip();

create or replace function public.record_cutting_transaction(
  requested_source_lot_id uuid,
  requested_source_quantity numeric,
  requested_occurred_at timestamptz,
  requested_performed_by text,
  requested_cut_type text,
  requested_outputs jsonb,
  requested_loss_quantity numeric default 0,
  requested_loss_reason text default null,
  requested_notes text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  source_lot public.intermediate_lots%rowtype;
  transformation_id uuid;
  generated_lot_id uuid;
  output_item jsonb;
  output_quantity numeric;
  output_total numeric := 0;
  output_product_id uuid;
  destination_id uuid;
  output_kind text;
  output_label text;
  pan111_product_id uuid;
  output_index integer := 0;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_source_quantity is null or requested_source_quantity <= 0 then
    raise exception 'Source weight must be greater than zero';
  end if;
  if length(trim(coalesce(requested_performed_by, ''))) = 0 then
    raise exception 'Cut by is required';
  end if;
  if jsonb_typeof(requested_outputs) <> 'array'
    or jsonb_array_length(requested_outputs) = 0 then
    raise exception 'At least one cutting output is required';
  end if;
  if coalesce(requested_loss_quantity, 0) < 0 then
    raise exception 'Loss cannot be negative';
  end if;
  if coalesce(requested_loss_quantity, 0) > 0
    and length(trim(coalesce(requested_loss_reason, ''))) = 0 then
    raise exception 'A loss reason is required';
  end if;

  select * into source_lot
  from public.intermediate_lots
  where id = requested_source_lot_id
  for update;

  if not found then raise exception 'Source intermediate lot does not exist'; end if;
  if source_lot.status not in ('available', 'reserved') then
    raise exception 'Source intermediate lot is not available';
  end if;
  if requested_source_quantity > source_lot.current_quantity then
    raise exception 'Cutting weight cannot exceed the available intermediate balance';
  end if;

  for output_item in select value from jsonb_array_elements(requested_outputs)
  loop
    output_quantity := (output_item ->> 'quantity')::numeric;
    if output_quantity is null or output_quantity <= 0 then
      raise exception 'Every cutting output must have a positive quantity';
    end if;
    output_total := output_total + output_quantity;
  end loop;

  if abs(output_total + coalesce(requested_loss_quantity, 0) - requested_source_quantity) > 0.001 then
    raise exception 'Cutting outputs plus loss must equal the source weight';
  end if;

  select id into pan111_product_id from public.products where code = 'PAN111';
  if pan111_product_id is null then raise exception 'PAN111 product is not configured'; end if;

  insert into public.transformations (
    transformation_type, source_batch_id, occurred_at, performed_by,
    cut_type, source_quantity, uom_id, loss_quantity, loss_reason,
    status, notes, created_by, updated_by
  ) values (
    'cutting', source_lot.source_batch_id, requested_occurred_at,
    trim(requested_performed_by), nullif(trim(requested_cut_type), ''),
    requested_source_quantity, source_lot.uom_id,
    coalesce(requested_loss_quantity, 0), nullif(trim(requested_loss_reason), ''),
    'completed', nullif(trim(requested_notes), ''), auth.uid(), auth.uid()
  ) returning id into transformation_id;

  insert into public.transformation_inputs (
    transformation_id, source_intermediate_lot_id, quantity, uom_id, created_by
  ) values (
    transformation_id, source_lot.id, requested_source_quantity,
    source_lot.uom_id, auth.uid()
  );

  update public.intermediate_lots
  set current_quantity = current_quantity - requested_source_quantity,
      status = case when current_quantity - requested_source_quantity = 0
        then 'depleted'::public.intermediate_lot_status
        else status end,
      updated_at = now(),
      updated_by = auth.uid()
  where id = source_lot.id;

  insert into public.intermediate_lot_movements (
    intermediate_lot_id, movement_type, quantity, uom_id,
    from_location_id, transformation_id, reference, occurred_at, created_by
  ) values (
    source_lot.id, 'transformation_input', requested_source_quantity,
    source_lot.uom_id, source_lot.storage_location_id, transformation_id,
    'Cutting input', requested_occurred_at, auth.uid()
  );

  for output_item in select value from jsonb_array_elements(requested_outputs)
  loop
    output_index := output_index + 1;
    output_quantity := (output_item ->> 'quantity')::numeric;
    output_kind := coalesce(nullif(output_item ->> 'kind', ''), 'primary');
    output_label := trim(coalesce(output_item ->> 'label', 'Cut output'));
    destination_id := (output_item ->> 'destination_location_id')::uuid;
    if destination_id is null then raise exception 'Every output needs a location'; end if;
    if output_kind not in ('primary', 'pan111', 'coproduct') then
      raise exception 'Invalid cutting output kind';
    end if;
    output_product_id := case when output_kind = 'pan111'
      then pan111_product_id else source_lot.product_id end;

    generated_lot_id := gen_random_uuid();
    insert into public.intermediate_lots (
      id, product_id, source_batch_id, source_transformation_id,
      parent_intermediate_lot_id, lot_code, display_label,
      produced_quantity, current_quantity, uom_id, storage_location_id,
      status, produced_at, created_by, updated_by
    ) values (
      generated_lot_id, output_product_id, source_lot.source_batch_id,
      transformation_id, source_lot.id,
      regexp_replace(source_lot.lot_code, '-UNCUT$', '') || '-CUT-' ||
        upper(substr(replace(transformation_id::text, '-', ''), 1, 6)) || '-' ||
        lpad(output_index::text, 2, '0'),
      output_label, output_quantity, output_quantity, source_lot.uom_id,
      destination_id, 'available', requested_occurred_at, auth.uid(), auth.uid()
    );

    insert into public.transformation_outputs (
      transformation_id, product_id, output_kind, output_label,
      quantity, uom_id, destination_location_id,
      generated_intermediate_lot_id, created_by
    ) values (
      transformation_id, output_product_id, output_kind, output_label,
      output_quantity, source_lot.uom_id, destination_id,
      generated_lot_id, auth.uid()
    );

    insert into public.intermediate_lot_movements (
      intermediate_lot_id, movement_type, quantity, uom_id,
      to_location_id, transformation_id, reference, occurred_at, created_by
    ) values (
      generated_lot_id, 'transformation_output', output_quantity,
      source_lot.uom_id, destination_id, transformation_id,
      output_label, requested_occurred_at, auth.uid()
    );
  end loop;

  if source_lot.source_batch_id is not null then
    update public.production_batches
    set status = 'cut',
        cut_by = trim(requested_performed_by),
        cutting_allocation = nullif(trim(requested_cut_type), ''),
        updated_at = now(),
        updated_by = auth.uid()
    where id = source_lot.source_batch_id and locked_at is null;
  end if;

  return transformation_id;
end;
$$;

create or replace function public.transfer_intermediate_stock(
  requested_lot_id uuid,
  requested_quantity numeric,
  requested_destination_location_id uuid,
  requested_occurred_at timestamptz default now(),
  requested_reference text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  source_lot public.intermediate_lots%rowtype;
  destination_exists boolean;
  result_lot_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Transfer quantity must be greater than zero';
  end if;

  select * into source_lot
  from public.intermediate_lots
  where id = requested_lot_id
  for update;
  if not found then raise exception 'Intermediate lot does not exist'; end if;
  if requested_quantity > source_lot.current_quantity then
    raise exception 'Transfer quantity cannot exceed available stock';
  end if;
  if requested_destination_location_id = source_lot.storage_location_id then
    raise exception 'Choose a different destination location';
  end if;
  select exists (
    select 1 from public.storage_locations
    where id = requested_destination_location_id and active
  ) into destination_exists;
  if not destination_exists then raise exception 'Destination location is unavailable'; end if;

  if requested_quantity = source_lot.current_quantity then
    result_lot_id := source_lot.id;
    update public.intermediate_lots
    set storage_location_id = requested_destination_location_id,
        updated_at = now(),
        updated_by = auth.uid()
    where id = source_lot.id;
  else
    result_lot_id := gen_random_uuid();
    update public.intermediate_lots
    set current_quantity = current_quantity - requested_quantity,
        updated_at = now(),
        updated_by = auth.uid()
    where id = source_lot.id;

    insert into public.intermediate_lots (
      id, product_id, source_batch_id, source_transformation_id,
      parent_intermediate_lot_id, lot_code, display_label,
      produced_quantity, current_quantity, uom_id, storage_location_id,
      status, produced_at, created_by, updated_by
    ) values (
      result_lot_id, source_lot.product_id, source_lot.source_batch_id,
      source_lot.source_transformation_id, source_lot.id,
      source_lot.lot_code || '-T-' ||
        upper(substr(replace(result_lot_id::text, '-', ''), 1, 6)),
      source_lot.display_label, requested_quantity, requested_quantity,
      source_lot.uom_id, requested_destination_location_id,
      'available', source_lot.produced_at, auth.uid(), auth.uid()
    );
  end if;

  insert into public.intermediate_lot_movements (
    intermediate_lot_id, movement_type, quantity, uom_id,
    from_location_id, to_location_id, reference, occurred_at, created_by
  ) values (
    result_lot_id, 'transfer', requested_quantity, source_lot.uom_id,
    source_lot.storage_location_id, requested_destination_location_id,
    nullif(trim(requested_reference), ''), requested_occurred_at, auth.uid()
  );

  return result_lot_id;
end;
$$;

create or replace function public.record_recovered_coproduct(
  requested_batch_id uuid,
  requested_quantity numeric,
  requested_destination_location_id uuid,
  requested_occurred_at timestamptz default now(),
  requested_notes text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  source_batch public.production_batches%rowtype;
  recovered_product_id uuid;
  kilogram_id uuid;
  destination_exists boolean;
  generated_lot_id uuid := gen_random_uuid();
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_quantity is null or requested_quantity <= 0 then
    raise exception 'Recovered quantity must be greater than zero';
  end if;

  select * into source_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production batch does not exist'; end if;
  if source_batch.status = 'cancelled' then
    raise exception 'Cannot record recovered stock against a cancelled batch';
  end if;

  select id into recovered_product_id from public.products where code = 'RECOVERED_CREAM';
  select id into kilogram_id from public.units_of_measure where code = 'kg';
  select exists (
    select 1 from public.storage_locations
    where id = requested_destination_location_id and active
  ) into destination_exists;
  if recovered_product_id is null or kilogram_id is null then
    raise exception 'Recovered cream or kilogram master data is not configured';
  end if;
  if not destination_exists then raise exception 'Destination location is unavailable'; end if;

  insert into public.intermediate_lots (
    id, product_id, source_batch_id, lot_code, display_label,
    produced_quantity, current_quantity, uom_id, storage_location_id,
    status, produced_at, created_by, updated_by
  ) values (
    generated_lot_id, recovered_product_id, source_batch.id,
    source_batch.batch_code || '-RC-' ||
      upper(substr(replace(generated_lot_id::text, '-', ''), 1, 6)),
    coalesce(nullif(trim(requested_notes), ''), 'Recovered cream'),
    requested_quantity, requested_quantity, kilogram_id,
    requested_destination_location_id, 'available',
    requested_occurred_at, auth.uid(), auth.uid()
  );

  insert into public.production_batch_outputs (
    batch_id, product_id, quantity, uom_id, output_type,
    destination_location_id, generated_intermediate_lot_id, created_by
  ) values (
    source_batch.id, recovered_product_id, requested_quantity, kilogram_id,
    'recovered', requested_destination_location_id, generated_lot_id, auth.uid()
  );

  insert into public.intermediate_lot_movements (
    intermediate_lot_id, movement_type, quantity, uom_id,
    to_location_id, reference, occurred_at, created_by
  ) values (
    generated_lot_id, 'production_output', requested_quantity, kilogram_id,
    requested_destination_location_id, 'Recovered cream from ' || source_batch.batch_code,
    requested_occurred_at, auth.uid()
  );

  return generated_lot_id;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'transformations',
    'intermediate_lots',
    'production_batch_outputs',
    'transformation_inputs',
    'transformation_outputs',
    'intermediate_lot_movements'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.current_user_role() is not null)',
      table_name || '_authenticated_select', table_name
    );
    execute format('grant select on public.%I to authenticated', table_name);
    execute format(
      'revoke insert, update, delete on public.%I from anon, authenticated',
      table_name
    );
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row_change()',
      table_name || '_audit', table_name
    );
  end loop;
end;
$$;

create trigger transformations_set_update_metadata
before update on public.transformations
for each row execute function public.set_profile_update_metadata();
create trigger intermediate_lots_set_update_metadata
before update on public.intermediate_lots
for each row execute function public.set_profile_update_metadata();

revoke all on function public.record_cutting_transaction(
  uuid, numeric, timestamptz, text, text, jsonb, numeric, text, text
) from public;
grant execute on function public.record_cutting_transaction(
  uuid, numeric, timestamptz, text, text, jsonb, numeric, text, text
) to authenticated;

revoke all on function public.transfer_intermediate_stock(
  uuid, numeric, uuid, timestamptz, text
) from public;
grant execute on function public.transfer_intermediate_stock(
  uuid, numeric, uuid, timestamptz, text
) to authenticated;

revoke all on function public.record_recovered_coproduct(
  uuid, numeric, uuid, timestamptz, text
) from public;
grant execute on function public.record_recovered_coproduct(
  uuid, numeric, uuid, timestamptz, text
) to authenticated;

commit;
