begin;

alter table public.production_batches
add column fresh_pack_exception boolean not null default false;

create or replace function public.prevent_paneer_cutting_skip()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  is_paneer boolean;
  has_cutting boolean;
begin
  if new.status = old.status then return new; end if;
  if new.fresh_pack_exception then return new; end if;
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

create type public.packing_run_status as enum ('completed', 'cancelled');
create type public.finished_stock_status as enum (
  'available',
  'reserved',
  'depleted',
  'quarantined'
);

create table public.packing_runs (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references public.skus(id),
  started_at timestamptz not null,
  completed_at timestamptz not null,
  storage_location_id uuid not null references public.storage_locations(id),
  status public.packing_run_status not null default 'completed',
  operator_team text not null check (length(trim(operator_team)) > 0),
  cases_produced integer not null default 0 check (cases_produced >= 0),
  loose_units_produced integer not null default 0 check (loose_units_produced >= 0),
  packets_per_case_used integer check (packets_per_case_used is null or packets_per_case_used > 0),
  total_packet_equivalent integer not null check (total_packet_equivalent > 0),
  input_quantity_kg numeric not null check (input_quantity_kg > 0),
  expected_packed_weight_kg numeric check (
    expected_packed_weight_kg is null or expected_packed_weight_kg > 0
  ),
  actual_packed_weight_kg numeric not null check (actual_packed_weight_kg > 0),
  yield_variance_kg numeric not null,
  fifo_overridden boolean not null default false,
  fifo_override_reason text,
  weight_variance_reason text,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  locked_at timestamptz not null default now(),
  locked_by uuid default auth.uid() references auth.users(id),
  check (cases_produced > 0 or loose_units_produced > 0),
  check (cases_produced = 0 or packets_per_case_used is not null)
);

create table public.packing_run_sources (
  id uuid primary key default gen_random_uuid(),
  packing_run_id uuid not null references public.packing_runs(id),
  intermediate_lot_id uuid not null references public.intermediate_lots(id),
  quantity_consumed numeric not null check (quantity_consumed > 0),
  uom_id uuid not null references public.units_of_measure(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  unique (packing_run_id, intermediate_lot_id)
);

create table public.packing_material_usage (
  id uuid primary key default gen_random_uuid(),
  packing_run_id uuid not null references public.packing_runs(id),
  material_name text not null check (length(trim(material_name)) > 0),
  standard_quantity numeric check (standard_quantity is null or standard_quantity >= 0),
  actual_quantity numeric not null check (actual_quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create table public.finished_stock_lots (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references public.skus(id),
  packing_run_id uuid not null unique references public.packing_runs(id),
  lot_code text not null unique,
  case_quantity integer not null default 0 check (case_quantity >= 0),
  loose_unit_quantity integer not null default 0 check (loose_unit_quantity >= 0),
  packet_equivalent integer not null check (packet_equivalent > 0),
  current_packet_quantity integer not null check (
    current_packet_quantity >= 0 and current_packet_quantity <= packet_equivalent
  ),
  packed_weight_kg numeric not null check (packed_weight_kg > 0),
  storage_location_id uuid not null references public.storage_locations(id),
  status public.finished_stock_status not null default 'available',
  produced_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  check ((current_packet_quantity = 0 and status = 'depleted') or current_packet_quantity > 0)
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id),
  sku_id uuid references public.skus(id),
  intermediate_lot_id uuid references public.intermediate_lots(id),
  finished_stock_lot_id uuid references public.finished_stock_lots(id),
  source_location_id uuid references public.storage_locations(id),
  destination_location_id uuid references public.storage_locations(id),
  movement_type text not null check (
    movement_type in ('pack_consumption', 'finished_production', 'transfer', 'handover', 'return', 'waste', 'correction')
  ),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  reference_type text not null,
  reference_id uuid not null,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  check (
    product_id is not null
    or sku_id is not null
    or intermediate_lot_id is not null
    or finished_stock_lot_id is not null
  )
);

create index packing_runs_completed_at_idx on public.packing_runs (completed_at desc);
create index packing_runs_sku_idx on public.packing_runs (sku_id);
create index packing_run_sources_run_idx on public.packing_run_sources (packing_run_id);
create index packing_run_sources_lot_idx on public.packing_run_sources (intermediate_lot_id);
create index packing_material_usage_run_idx on public.packing_material_usage (packing_run_id);
create index finished_stock_lots_sku_idx on public.finished_stock_lots (sku_id);
create index finished_stock_lots_status_idx on public.finished_stock_lots (status);
create index finished_stock_lots_location_idx
on public.finished_stock_lots (storage_location_id);
create index stock_movements_reference_idx
on public.stock_movements (reference_type, reference_id);
create index stock_movements_intermediate_idx
on public.stock_movements (intermediate_lot_id);
create index stock_movements_finished_idx
on public.stock_movements (finished_stock_lot_id);

create or replace function public.complete_packing_run(
  requested_sku_id uuid,
  requested_completed_at timestamptz,
  requested_operator_team text,
  requested_cases integer,
  requested_loose_units integer,
  requested_packets_per_case_override integer,
  requested_actual_packed_weight_kg numeric,
  requested_sources jsonb,
  requested_fifo_override_reason text,
  requested_weight_variance_reason text,
  requested_wrappers_used numeric,
  requested_cases_used numeric,
  requested_destination_location_id uuid,
  requested_notes text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  sku_product_id uuid;
  sku_code text;
  sku_unit_weight_g numeric;
  configured_packets_per_case integer;
  packets_per_case_used integer;
  total_packets integer;
  expected_weight numeric;
  actual_weight numeric;
  kilogram_id uuid;
  packet_uom_id uuid;
  case_uom_id uuid;
  source_item jsonb;
  source_lot public.intermediate_lots%rowtype;
  source_quantity numeric;
  source_total numeric := 0;
  source_count integer;
  distinct_source_count integer;
  oldest_lot_id uuid;
  includes_oldest boolean := false;
  fifo_overridden boolean := false;
  packing_run_id uuid := gen_random_uuid();
  finished_lot_id uuid := gen_random_uuid();
  batch_record record;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if length(trim(coalesce(requested_operator_team, ''))) = 0 then
    raise exception 'Packing operator or team is required';
  end if;
  if coalesce(requested_cases, 0) < 0 or coalesce(requested_loose_units, 0) < 0 then
    raise exception 'Cases and loose packets cannot be negative';
  end if;
  if coalesce(requested_cases, 0) = 0 and coalesce(requested_loose_units, 0) = 0 then
    raise exception 'Record at least one case or loose packet';
  end if;
  if jsonb_typeof(requested_sources) <> 'array'
    or jsonb_array_length(requested_sources) = 0 then
    raise exception 'At least one intermediate source lot is required';
  end if;

  select s.product_id, s.code, s.unit_weight_g
  into sku_product_id, sku_code, sku_unit_weight_g
  from public.skus s
  where s.id = requested_sku_id and s.active;
  if not found then raise exception 'Finished SKU is unavailable'; end if;

  select pc.packets_per_case into configured_packets_per_case
  from public.packaging_configs pc
  where pc.sku_id = requested_sku_id
    and pc.effective_from <= requested_completed_at::date
    and (pc.effective_to is null or pc.effective_to >= requested_completed_at::date)
  order by pc.effective_from desc
  limit 1;

  packets_per_case_used := coalesce(
    requested_packets_per_case_override,
    configured_packets_per_case
  );
  if coalesce(requested_cases, 0) > 0
    and coalesce(packets_per_case_used, 0) <= 0 then
    raise exception 'Packets per case is required for this packing run';
  end if;
  if requested_packets_per_case_override is not null
    and requested_packets_per_case_override <= 0 then
    raise exception 'Packets per case override must be positive';
  end if;

  total_packets := coalesce(requested_cases, 0) * coalesce(packets_per_case_used, 0)
    + coalesce(requested_loose_units, 0);
  expected_weight := case when sku_unit_weight_g is null then null
    else total_packets * sku_unit_weight_g / 1000 end;
  actual_weight := coalesce(requested_actual_packed_weight_kg, expected_weight);
  if actual_weight is null or actual_weight <= 0 then
    raise exception 'Actual packed weight is required for this SKU';
  end if;

  select id into kilogram_id from public.units_of_measure where code = 'kg';
  select id into packet_uom_id from public.units_of_measure where code = 'packet';
  select id into case_uom_id from public.units_of_measure where code = 'case';
  if kilogram_id is null or packet_uom_id is null or case_uom_id is null then
    raise exception 'Required kg, packet, and case units are not configured';
  end if;
  if not exists (
    select 1 from public.storage_locations
    where id = requested_destination_location_id and active
  ) then raise exception 'Finished-stock destination is unavailable'; end if;

  select count(*), count(distinct (value ->> 'intermediate_lot_id'))
  into source_count, distinct_source_count
  from jsonb_array_elements(requested_sources);
  if source_count <> distinct_source_count then
    raise exception 'The same intermediate lot cannot be selected twice';
  end if;

  perform 1
  from public.intermediate_lots il
  where il.id in (
    select (value ->> 'intermediate_lot_id')::uuid
    from jsonb_array_elements(requested_sources)
  )
  order by il.id
  for update;

  select il.id into oldest_lot_id
  from public.intermediate_lots il
  left join public.production_batches pb on pb.id = il.source_batch_id
  left join public.production_shifts ps on ps.id = pb.shift_id
  left join public.storage_locations sl on sl.id = il.storage_location_id
  where il.product_id = sku_product_id
    and il.status = 'available'
    and il.current_quantity > 0
    and (sku_code in ('MPAN010', 'RPAN010') or sl.code = 'INTERMEDIATE_FREEZER')
  order by il.produced_at, coalesce(ps.shift_number, 0), coalesce(pb.round_number, 0)
  limit 1;

  for source_item in select value from jsonb_array_elements(requested_sources)
  loop
    source_quantity := (source_item ->> 'quantity')::numeric;
    if source_quantity is null or source_quantity <= 0 then
      raise exception 'Every source quantity must be positive';
    end if;
    select * into source_lot
    from public.intermediate_lots
    where id = (source_item ->> 'intermediate_lot_id')::uuid;
    if not found then raise exception 'Intermediate source lot does not exist'; end if;
    if source_lot.product_id <> sku_product_id then
      raise exception 'Intermediate source product does not match the selected SKU';
    end if;
    if source_lot.status not in ('available', 'reserved')
      or source_quantity > source_lot.current_quantity then
      raise exception 'Packing source quantity exceeds available stock';
    end if;
    if source_lot.uom_id <> kilogram_id then
      raise exception 'Packing source stock must be recorded in kilograms';
    end if;
    if sku_code not in ('MPAN010', 'RPAN010') and not exists (
      select 1 from public.storage_locations
      where id = source_lot.storage_location_id and code = 'INTERMEDIATE_FREEZER'
    ) then
      raise exception 'Normal packing must use stock held in the intermediate freezer';
    end if;
    if source_lot.id = oldest_lot_id then includes_oldest := true; end if;
    source_total := source_total + source_quantity;
  end loop;

  fifo_overridden := oldest_lot_id is not null and not includes_oldest;
  if actual_weight > source_total
    and length(trim(coalesce(requested_weight_variance_reason, ''))) = 0 then
    raise exception 'Packed weight cannot exceed consumed stock without a variance reason';
  end if;

  insert into public.packing_runs (
    id, sku_id, started_at, completed_at, storage_location_id,
    status, operator_team, cases_produced, loose_units_produced,
    packets_per_case_used, total_packet_equivalent, input_quantity_kg,
    expected_packed_weight_kg, actual_packed_weight_kg, yield_variance_kg,
    fifo_overridden, fifo_override_reason, weight_variance_reason,
    notes, created_by, updated_by, locked_by
  ) values (
    packing_run_id, requested_sku_id, requested_completed_at,
    requested_completed_at, requested_destination_location_id,
    'completed', trim(requested_operator_team), coalesce(requested_cases, 0),
    coalesce(requested_loose_units, 0), packets_per_case_used, total_packets,
    source_total, expected_weight, actual_weight, source_total - actual_weight,
    fifo_overridden, nullif(trim(requested_fifo_override_reason), ''),
    nullif(trim(requested_weight_variance_reason), ''),
    nullif(trim(requested_notes), ''), auth.uid(), auth.uid(), auth.uid()
  );

  for source_item in select value from jsonb_array_elements(requested_sources)
  loop
    source_quantity := (source_item ->> 'quantity')::numeric;
    select * into source_lot
    from public.intermediate_lots
    where id = (source_item ->> 'intermediate_lot_id')::uuid;

    insert into public.packing_run_sources (
      packing_run_id, intermediate_lot_id, quantity_consumed, uom_id, created_by
    ) values (
      packing_run_id, source_lot.id, source_quantity, kilogram_id, auth.uid()
    );

    update public.intermediate_lots
    set current_quantity = current_quantity - source_quantity,
        status = case when current_quantity - source_quantity = 0
          then 'depleted'::public.intermediate_lot_status
          else status end,
        updated_at = now(),
        updated_by = auth.uid()
    where id = source_lot.id;

    insert into public.stock_movements (
      product_id, intermediate_lot_id, source_location_id,
      movement_type, quantity, uom_id, reference_type,
      reference_id, occurred_at, created_by
    ) values (
      source_lot.product_id, source_lot.id, source_lot.storage_location_id,
      'pack_consumption', source_quantity, kilogram_id, 'packing_run',
      packing_run_id, requested_completed_at, auth.uid()
    );
  end loop;

  insert into public.finished_stock_lots (
    id, sku_id, packing_run_id, lot_code, case_quantity,
    loose_unit_quantity, packet_equivalent, current_packet_quantity, packed_weight_kg,
    storage_location_id, status, produced_at, created_by, updated_by
  ) values (
    finished_lot_id, requested_sku_id,
    packing_run_id, sku_code || '-' || to_char(requested_completed_at, 'YYMMDD') ||
      '-' || upper(substr(replace(packing_run_id::text, '-', ''), 1, 6)),
    coalesce(requested_cases, 0), coalesce(requested_loose_units, 0),
    total_packets, total_packets, actual_weight, requested_destination_location_id,
    'available', requested_completed_at, auth.uid(), auth.uid()
  );

  insert into public.stock_movements (
    sku_id, finished_stock_lot_id, destination_location_id,
    movement_type, quantity, uom_id, reference_type,
    reference_id, occurred_at, created_by
  ) values (
    requested_sku_id, finished_lot_id, requested_destination_location_id,
    'finished_production', total_packets, packet_uom_id, 'packing_run',
    packing_run_id, requested_completed_at, auth.uid()
  );

  if coalesce(requested_wrappers_used, 0) > 0 then
    insert into public.packing_material_usage (
      packing_run_id, material_name, standard_quantity,
      actual_quantity, uom_id, created_by
    ) values (
      packing_run_id, 'Product wrappers / packets', total_packets,
      requested_wrappers_used, packet_uom_id, auth.uid()
    );
  end if;
  if coalesce(requested_cases_used, 0) > 0 then
    insert into public.packing_material_usage (
      packing_run_id, material_name, standard_quantity,
      actual_quantity, uom_id, created_by
    ) values (
      packing_run_id, 'Cases / boxes', requested_cases,
      requested_cases_used, case_uom_id, auth.uid()
    );
  end if;

  for batch_record in
    select distinct il.source_batch_id
    from jsonb_array_elements(requested_sources) source_json
    join public.intermediate_lots il
      on il.id = (source_json.value ->> 'intermediate_lot_id')::uuid
    where il.source_batch_id is not null
  loop
    update public.production_batches pb
    set fresh_pack_exception = pb.fresh_pack_exception
          or sku_code in ('MPAN010', 'RPAN010'),
        status = case when exists (
          select 1 from public.intermediate_lots remaining_lot
          where remaining_lot.source_batch_id = pb.id
            and remaining_lot.product_id = sku_product_id
            and remaining_lot.current_quantity > 0
        ) then 'part_packed'::public.production_status
          else 'packed'::public.production_status end,
        updated_at = now(),
        updated_by = auth.uid()
    where pb.id = batch_record.source_batch_id and pb.locked_at is null;
  end loop;

  return packing_run_id;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'packing_runs',
    'packing_run_sources',
    'packing_material_usage',
    'finished_stock_lots',
    'stock_movements'
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

create trigger packing_runs_set_update_metadata
before update on public.packing_runs
for each row execute function public.set_profile_update_metadata();
create trigger finished_stock_lots_set_update_metadata
before update on public.finished_stock_lots
for each row execute function public.set_profile_update_metadata();

revoke all on function public.complete_packing_run(
  uuid, timestamptz, text, integer, integer, integer, numeric,
  jsonb, text, text, numeric, numeric, uuid, text
) from public;
grant execute on function public.complete_packing_run(
  uuid, timestamptz, text, integer, integer, integer, numeric,
  jsonb, text, text, numeric, numeric, uuid, text
) to authenticated;

commit;
