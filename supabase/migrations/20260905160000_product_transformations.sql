begin;

insert into public.products (
  family_id, code, name, product_type, variant, weight_mode
) values
  (
    (select id from public.product_families where code = 'HALLOUMI'),
    'RAW_HALLOUMI',
    'Raw Halloumi',
    'intermediate',
    null,
    'variable'
  ),
  (
    (select id from public.product_families where code = 'HALLOUMI'),
    'CUT_HALLOUMI',
    'Cut Halloumi',
    'intermediate',
    null,
    'variable'
  ),
  (
    (select id from public.product_families where code = 'POPPERS'),
    'CREAM_CHEESE_FILLING',
    'Jalapeño Cream-Cheese Filling',
    'intermediate',
    'JP filling',
    'variable'
  )
on conflict (code) do nothing;

alter table public.transformations
drop constraint transformations_transformation_type_check;
alter table public.transformations
add constraint transformations_transformation_type_check check (
  transformation_type in (
    'cutting',
    'blending',
    'filling',
    'coating',
    'frying',
    'cooking',
    'churning',
    'ghee_cooking',
    'freezing'
  )
);
alter table public.transformations
add column process_template text,
add column recipe_version_id uuid references public.recipe_versions(id);

alter table public.transformation_inputs
add column standard_quantity numeric check (
  standard_quantity is null or standard_quantity > 0
),
add column variance_quantity numeric;

alter table public.inventory_movements
add column transformation_id uuid references public.transformations(id);

create table public.transformation_source_lot_inputs (
  id uuid primary key default gen_random_uuid(),
  transformation_id uuid not null references public.transformations(id),
  source_lot_id uuid not null references public.source_lots(id),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  unique (transformation_id, source_lot_id)
);

create table public.transformation_inventory_inputs (
  id uuid primary key default gen_random_uuid(),
  transformation_id uuid not null references public.transformations(id),
  inventory_lot_id uuid not null references public.inventory_lots(id),
  source_location_id uuid not null references public.storage_locations(id),
  quantity numeric not null check (quantity > 0),
  standard_quantity numeric check (standard_quantity is null or standard_quantity > 0),
  variance_quantity numeric,
  uom_id uuid not null references public.units_of_measure(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  unique (transformation_id, inventory_lot_id, source_location_id)
);

create table public.transformation_process_controls (
  id uuid primary key default gen_random_uuid(),
  transformation_id uuid not null references public.transformations(id),
  control_code text not null,
  control_label text not null,
  numeric_value numeric,
  text_value text,
  uom_label text,
  target_value numeric,
  min_value numeric,
  max_value numeric,
  in_spec boolean,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  check (num_nonnulls(numeric_value, text_value) = 1),
  check (min_value is null or max_value is null or min_value <= max_value),
  unique (transformation_id, control_code)
);

create index transformation_source_inputs_transformation_idx
on public.transformation_source_lot_inputs (transformation_id);
create index transformation_source_inputs_lot_idx
on public.transformation_source_lot_inputs (source_lot_id);
create index transformation_inventory_inputs_transformation_idx
on public.transformation_inventory_inputs (transformation_id);
create index transformation_inventory_inputs_lot_idx
on public.transformation_inventory_inputs (inventory_lot_id);
create index transformation_controls_transformation_idx
on public.transformation_process_controls (transformation_id);
create index inventory_movements_transformation_idx
on public.inventory_movements (transformation_id);

create or replace view public.source_lot_available_balances
with (security_invoker = true)
as
select
  source.id as source_lot_id,
  source.received_quantity,
  source.received_quantity
    - coalesce((
      select sum(batch.actual_primary_input_quantity)
      from public.production_batches batch
      where batch.parent_source_lot_id = source.id
        and batch.status <> 'cancelled'
    ), 0)
    - coalesce((
      select sum(input.quantity)
      from public.transformation_source_lot_inputs input
      join public.transformations transformation
        on transformation.id = input.transformation_id
      where input.source_lot_id = source.id
        and transformation.status = 'completed'
    ), 0) as available_quantity
from public.source_lots source;

grant select on public.source_lot_available_balances to authenticated;

create or replace function public.record_process_transformation(
  requested_transformation_type text,
  requested_process_template text,
  requested_occurred_at timestamptz,
  requested_performed_by text,
  requested_recipe_version_id uuid,
  requested_intermediate_inputs jsonb,
  requested_source_lot_inputs jsonb,
  requested_inventory_inputs jsonb,
  requested_outputs jsonb,
  requested_controls jsonb,
  requested_notes text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  transformation_id uuid := gen_random_uuid();
  generated_lot_id uuid;
  input_item jsonb;
  output_item jsonb;
  control_item jsonb;
  source_intermediate public.intermediate_lots%rowtype;
  source_lot public.source_lots%rowtype;
  inventory_lot public.inventory_lots%rowtype;
  input_quantity numeric;
  standard_quantity numeric;
  available_quantity numeric;
  consumed_source_quantity numeric;
  output_quantity numeric;
  output_product_id uuid;
  output_uom_id uuid;
  destination_id uuid;
  output_kind text;
  output_label text;
  primary_quantity numeric;
  primary_uom_id uuid;
  primary_source_batch_id uuid;
  primary_parent_intermediate_id uuid;
  output_index integer := 0;
  control_numeric numeric;
  control_min numeric;
  control_max numeric;
  control_in_spec boolean;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_transformation_type not in (
    'cutting', 'blending', 'filling', 'coating', 'frying',
    'cooking', 'churning', 'ghee_cooking', 'freezing'
  ) then raise exception 'Unsupported transformation type'; end if;
  if length(trim(coalesce(requested_process_template, ''))) = 0 then
    raise exception 'Process template is required';
  end if;
  if length(trim(coalesce(requested_performed_by, ''))) = 0 then
    raise exception 'Operator or team is required';
  end if;
  if jsonb_typeof(requested_intermediate_inputs) <> 'array'
    or jsonb_typeof(requested_source_lot_inputs) <> 'array'
    or jsonb_typeof(requested_inventory_inputs) <> 'array'
    or jsonb_typeof(requested_outputs) <> 'array'
    or jsonb_typeof(requested_controls) <> 'array' then
    raise exception 'Transformation inputs, outputs, and controls must be arrays';
  end if;
  if jsonb_array_length(requested_intermediate_inputs)
      + jsonb_array_length(requested_source_lot_inputs)
      + jsonb_array_length(requested_inventory_inputs) = 0 then
    raise exception 'At least one transformation input is required';
  end if;
  if jsonb_array_length(requested_outputs) = 0 then
    raise exception 'At least one transformation output is required';
  end if;
  if requested_recipe_version_id is not null and not exists (
    select 1
    from public.recipe_versions version
    where version.id = requested_recipe_version_id
      and public.can_read_recipe(version.recipe_id)
  ) then raise exception 'Recipe version does not exist'; end if;

  perform 1 from public.intermediate_lots il
  where il.id in (
    select (value ->> 'intermediate_lot_id')::uuid
    from jsonb_array_elements(requested_intermediate_inputs)
  )
  order by il.id for update;
  perform 1 from public.source_lots sl
  where sl.id in (
    select (value ->> 'source_lot_id')::uuid
    from jsonb_array_elements(requested_source_lot_inputs)
  )
  order by sl.id for update;
  perform 1 from public.inventory_lots inventory
  where inventory.id in (
    select (value ->> 'inventory_lot_id')::uuid
    from jsonb_array_elements(requested_inventory_inputs)
  )
  order by inventory.id for update;

  if jsonb_array_length(requested_intermediate_inputs) > 0 then
    input_item := requested_intermediate_inputs -> 0;
    select * into source_intermediate
    from public.intermediate_lots
    where id = (input_item ->> 'intermediate_lot_id')::uuid;
    primary_quantity := (input_item ->> 'quantity')::numeric;
    primary_uom_id := source_intermediate.uom_id;
    primary_source_batch_id := source_intermediate.source_batch_id;
    primary_parent_intermediate_id := source_intermediate.id;
  elsif jsonb_array_length(requested_source_lot_inputs) > 0 then
    input_item := requested_source_lot_inputs -> 0;
    select * into source_lot
    from public.source_lots
    where id = (input_item ->> 'source_lot_id')::uuid;
    primary_quantity := (input_item ->> 'quantity')::numeric;
    primary_uom_id := source_lot.uom_id;
  else
    input_item := requested_inventory_inputs -> 0;
    select * into inventory_lot
    from public.inventory_lots
    where id = (input_item ->> 'inventory_lot_id')::uuid;
    primary_quantity := (input_item ->> 'quantity')::numeric;
    primary_uom_id := inventory_lot.uom_id;
  end if;

  if primary_quantity is null or primary_quantity <= 0 then
    raise exception 'Primary input quantity must be positive';
  end if;

  insert into public.transformations (
    id, transformation_type, process_template, source_batch_id,
    recipe_version_id, occurred_at, performed_by, cut_type,
    source_quantity, uom_id, loss_quantity, status, notes,
    created_by, updated_by, locked_at, locked_by
  ) values (
    transformation_id, requested_transformation_type,
    trim(requested_process_template), primary_source_batch_id,
    requested_recipe_version_id, requested_occurred_at,
    trim(requested_performed_by), null, primary_quantity,
    primary_uom_id, 0, 'completed', nullif(trim(requested_notes), ''),
    auth.uid(), auth.uid(), now(), auth.uid()
  );

  for input_item in select value from jsonb_array_elements(requested_intermediate_inputs)
  loop
    input_quantity := (input_item ->> 'quantity')::numeric;
    standard_quantity := nullif(input_item ->> 'standard_quantity', '')::numeric;
    select * into source_intermediate
    from public.intermediate_lots
    where id = (input_item ->> 'intermediate_lot_id')::uuid;
    if not found then raise exception 'Intermediate input lot does not exist'; end if;
    if input_quantity is null or input_quantity <= 0
      or input_quantity > source_intermediate.current_quantity then
      raise exception 'Intermediate input exceeds available stock';
    end if;
    if source_intermediate.status not in ('available', 'reserved') then
      raise exception 'Intermediate input is unavailable';
    end if;

    insert into public.transformation_inputs (
      transformation_id, source_intermediate_lot_id, quantity,
      standard_quantity, variance_quantity, uom_id, created_by
    ) values (
      transformation_id, source_intermediate.id, input_quantity,
      standard_quantity,
      case when standard_quantity is null then null
        else input_quantity - standard_quantity end,
      source_intermediate.uom_id, auth.uid()
    );
    update public.intermediate_lots
    set current_quantity = current_quantity - input_quantity,
        status = case when current_quantity - input_quantity = 0
          then 'depleted'::public.intermediate_lot_status else status end,
        updated_at = now(), updated_by = auth.uid()
    where id = source_intermediate.id;
    insert into public.intermediate_lot_movements (
      intermediate_lot_id, movement_type, quantity, uom_id,
      from_location_id, transformation_id, reference, occurred_at, created_by
    ) values (
      source_intermediate.id, 'transformation_input', input_quantity,
      source_intermediate.uom_id, source_intermediate.storage_location_id,
      transformation_id, requested_process_template, requested_occurred_at, auth.uid()
    );
  end loop;

  for input_item in select value from jsonb_array_elements(requested_source_lot_inputs)
  loop
    input_quantity := (input_item ->> 'quantity')::numeric;
    select * into source_lot
    from public.source_lots
    where id = (input_item ->> 'source_lot_id')::uuid;
    if not found then raise exception 'Source lot does not exist'; end if;
    if source_lot.status = 'rejected' then raise exception 'Rejected source lot cannot be used'; end if;
    if input_quantity is null or input_quantity <= 0 then
      raise exception 'Source lot input quantity must be positive';
    end if;

    select
      coalesce((
        select sum(pb.actual_primary_input_quantity)
        from public.production_batches pb
        where pb.parent_source_lot_id = source_lot.id
          and pb.status <> 'cancelled'
      ), 0)
      + coalesce((
        select sum(tsli.quantity)
        from public.transformation_source_lot_inputs tsli
        join public.transformations existing_t on existing_t.id = tsli.transformation_id
        where tsli.source_lot_id = source_lot.id
          and existing_t.status = 'completed'
      ), 0)
    into consumed_source_quantity;
    if consumed_source_quantity + input_quantity > source_lot.received_quantity then
      raise exception 'Source input exceeds the received lot balance';
    end if;

    insert into public.transformation_source_lot_inputs (
      transformation_id, source_lot_id, quantity, uom_id, created_by
    ) values (
      transformation_id, source_lot.id, input_quantity, source_lot.uom_id, auth.uid()
    );
  end loop;

  for input_item in select value from jsonb_array_elements(requested_inventory_inputs)
  loop
    input_quantity := (input_item ->> 'quantity')::numeric;
    standard_quantity := nullif(input_item ->> 'standard_quantity', '')::numeric;
    select * into inventory_lot
    from public.inventory_lots
    where id = (input_item ->> 'inventory_lot_id')::uuid;
    if not found then raise exception 'Inventory input lot does not exist'; end if;
    if input_quantity is null or input_quantity <= 0 then
      raise exception 'Inventory input quantity must be positive';
    end if;
    available_quantity := public.current_inventory_balance(
      inventory_lot.id, (input_item ->> 'source_location_id')::uuid
    );
    if input_quantity > available_quantity then
      raise exception 'Inventory input exceeds available stock';
    end if;

    insert into public.transformation_inventory_inputs (
      transformation_id, inventory_lot_id, source_location_id,
      quantity, standard_quantity, variance_quantity, uom_id, created_by
    ) values (
      transformation_id, inventory_lot.id,
      (input_item ->> 'source_location_id')::uuid,
      input_quantity, standard_quantity,
      case when standard_quantity is null then null
        else input_quantity - standard_quantity end,
      inventory_lot.uom_id, auth.uid()
    );
    insert into public.inventory_movements (
      inventory_item_id, inventory_lot_id, source_location_id,
      movement_type, quantity, uom_id, transformation_id,
      notes, occurred_at, created_by
    ) values (
      inventory_lot.inventory_item_id, inventory_lot.id,
      (input_item ->> 'source_location_id')::uuid,
      'consume', input_quantity, inventory_lot.uom_id, transformation_id,
      requested_process_template, requested_occurred_at, auth.uid()
    );
  end loop;

  for output_item in select value from jsonb_array_elements(requested_outputs)
  loop
    output_index := output_index + 1;
    output_quantity := (output_item ->> 'quantity')::numeric;
    output_product_id := (output_item ->> 'product_id')::uuid;
    output_uom_id := (output_item ->> 'uom_id')::uuid;
    destination_id := (output_item ->> 'destination_location_id')::uuid;
    output_kind := coalesce(nullif(output_item ->> 'kind', ''), 'primary');
    output_label := trim(coalesce(output_item ->> 'label', requested_process_template));
    if output_quantity is null or output_quantity <= 0 then
      raise exception 'Every output quantity must be positive';
    end if;
    if not exists (select 1 from public.products where id = output_product_id and active) then
      raise exception 'Output product is unavailable';
    end if;
    if not exists (select 1 from public.units_of_measure where id = output_uom_id and active) then
      raise exception 'Output unit is unavailable';
    end if;
    if not exists (select 1 from public.storage_locations where id = destination_id and active) then
      raise exception 'Output location is unavailable';
    end if;
    if output_kind not in ('primary', 'pan111', 'coproduct') then
      raise exception 'Invalid output kind';
    end if;

    generated_lot_id := gen_random_uuid();
    insert into public.intermediate_lots (
      id, product_id, source_batch_id, source_transformation_id,
      parent_intermediate_lot_id, lot_code, display_label,
      produced_quantity, current_quantity, uom_id, storage_location_id,
      status, produced_at, created_by, updated_by
    ) values (
      generated_lot_id, output_product_id, primary_source_batch_id,
      transformation_id, primary_parent_intermediate_id,
      'TR-' || to_char(requested_occurred_at, 'YYMMDD') || '-' ||
        upper(substr(regexp_replace(requested_process_template, '[^a-zA-Z0-9]', '', 'g'), 1, 8)) ||
        '-' || upper(substr(replace(transformation_id::text, '-', ''), 1, 6)) ||
        '-' || lpad(output_index::text, 2, '0'),
      output_label, output_quantity, output_quantity, output_uom_id,
      destination_id, 'available', requested_occurred_at, auth.uid(), auth.uid()
    );
    insert into public.transformation_outputs (
      transformation_id, product_id, output_kind, output_label,
      quantity, uom_id, destination_location_id,
      generated_intermediate_lot_id, created_by
    ) values (
      transformation_id, output_product_id, output_kind, output_label,
      output_quantity, output_uom_id, destination_id, generated_lot_id, auth.uid()
    );
    insert into public.intermediate_lot_movements (
      intermediate_lot_id, movement_type, quantity, uom_id,
      to_location_id, transformation_id, reference, occurred_at, created_by
    ) values (
      generated_lot_id, 'transformation_output', output_quantity,
      output_uom_id, destination_id, transformation_id,
      output_label, requested_occurred_at, auth.uid()
    );
  end loop;

  for control_item in select value from jsonb_array_elements(requested_controls)
  loop
    if length(trim(coalesce(control_item ->> 'code', ''))) = 0
      or length(trim(coalesce(control_item ->> 'label', ''))) = 0 then
      raise exception 'Every process control requires a code and label';
    end if;
    control_numeric := nullif(control_item ->> 'numeric_value', '')::numeric;
    control_min := nullif(control_item ->> 'min_value', '')::numeric;
    control_max := nullif(control_item ->> 'max_value', '')::numeric;
    control_in_spec := case
      when control_numeric is null then null
      when control_min is not null and control_numeric < control_min then false
      when control_max is not null and control_numeric > control_max then false
      else true
    end;
    if control_numeric is null
      and length(trim(coalesce(control_item ->> 'text_value', ''))) = 0 then
      raise exception 'Every process control requires a recorded value';
    end if;
    insert into public.transformation_process_controls (
      transformation_id, control_code, control_label,
      numeric_value, text_value, uom_label, target_value,
      min_value, max_value, in_spec, created_by
    ) values (
      transformation_id,
      trim(control_item ->> 'code'),
      trim(control_item ->> 'label'),
      control_numeric,
      case when control_numeric is null
        then nullif(trim(control_item ->> 'text_value'), '') else null end,
      nullif(trim(control_item ->> 'uom_label'), ''),
      nullif(control_item ->> 'target_value', '')::numeric,
      control_min, control_max, control_in_spec, auth.uid()
    );
  end loop;

  return transformation_id;
end;
$$;

alter table public.transformation_source_lot_inputs enable row level security;
alter table public.transformation_inventory_inputs enable row level security;
alter table public.transformation_process_controls enable row level security;

create policy transformation_source_lot_inputs_select
on public.transformation_source_lot_inputs
for select to authenticated using (public.current_user_role() is not null);
create policy transformation_inventory_inputs_select
on public.transformation_inventory_inputs
for select to authenticated using (public.current_user_role() is not null);
create policy transformation_process_controls_select
on public.transformation_process_controls
for select to authenticated using (public.current_user_role() is not null);

grant select on
  public.transformation_source_lot_inputs,
  public.transformation_inventory_inputs,
  public.transformation_process_controls
to authenticated;
revoke insert, update, delete on
  public.transformation_source_lot_inputs,
  public.transformation_inventory_inputs,
  public.transformation_process_controls
from anon, authenticated;

create trigger transformation_source_lot_inputs_audit
after insert or update or delete on public.transformation_source_lot_inputs
for each row execute function public.audit_row_change();
create trigger transformation_inventory_inputs_audit
after insert or update or delete on public.transformation_inventory_inputs
for each row execute function public.audit_row_change();
create trigger transformation_process_controls_audit
after insert or update or delete on public.transformation_process_controls
for each row execute function public.audit_row_change();

revoke all on function public.record_process_transformation(
  text, text, timestamptz, text, uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text
) from public;
grant execute on function public.record_process_transformation(
  text, text, timestamptz, text, uuid, jsonb, jsonb, jsonb, jsonb, jsonb, text
) to authenticated;

commit;
