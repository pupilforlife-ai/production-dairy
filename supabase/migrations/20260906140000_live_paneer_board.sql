begin;

create type public.paneer_process_stage as enum (
  'vat_1',
  'vat_2',
  'vat_3',
  'coagulation',
  'presses',
  'cooling_tank',
  'chiller',
  'resting',
  'ready_for_cutting'
);

create type public.paneer_cut_format as enum (
  'cubes_200g',
  'cubes_400g',
  'spp',
  'restaurant_blocks'
);

alter table public.production_batches
add column milk_start_temperature_c numeric check (
  milk_start_temperature_c is null
  or (milk_start_temperature_c >= -10 and milk_start_temperature_c <= 110)
),
add column process_stage public.paneer_process_stage not null default 'vat_1',
add column process_stage_changed_at timestamptz not null default now(),
add column cut_format public.paneer_cut_format,
add column cut_completed_at timestamptz;

update public.production_batches
set process_stage = case
  when status = 'pressing'::public.production_status
    then 'presses'::public.paneer_process_stage
  when status = any(array[
    'ready_for_cutting', 'cut', 'freezing', 'frozen_ready_for_packing',
    'part_packed', 'packed', 'ready_for_handover', 'handed_over'
  ]::public.production_status[])
    then 'ready_for_cutting'::public.paneer_process_stage
  else 'vat_1'::public.paneer_process_stage
end,
process_stage_changed_at = coalesce(updated_at, created_at);

create table public.production_batch_stage_events (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  stage public.paneer_process_stage not null,
  changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

insert into public.production_batch_stage_events (
  production_batch_id, stage, changed_at, created_by
)
select id, process_stage, process_stage_changed_at, created_by
from public.production_batches;

create table public.production_round_packing_entries (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  sku_id uuid not null references public.skus(id),
  cases integer not null default 0 check (cases >= 0),
  loose_packets integer not null default 0 check (loose_packets >= 0),
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  check (cases > 0 or loose_packets > 0)
);

create index production_batch_stage_events_batch_idx
on public.production_batch_stage_events (production_batch_id, changed_at desc);
create index production_round_packing_entries_batch_idx
on public.production_round_packing_entries (production_batch_id, recorded_at);

create or replace function public.record_production_stage_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.process_stage is distinct from old.process_stage then
    if tg_op = 'UPDATE' then new.process_stage_changed_at := now(); end if;
  end if;
  return new;
end;
$$;

create trigger production_batches_set_stage_time
before insert or update on public.production_batches
for each row execute function public.record_production_stage_event();

create or replace function public.append_production_stage_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.process_stage is distinct from old.process_stage then
    insert into public.production_batch_stage_events (
      production_batch_id, stage, changed_at, created_by
    ) values (
      new.id, new.process_stage, new.process_stage_changed_at, auth.uid()
    );
  end if;
  return new;
end;
$$;

create trigger production_batches_append_stage_event
after insert or update on public.production_batches
for each row execute function public.append_production_stage_event();

create or replace function public.add_live_production_round(requested_shift_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_shift public.production_shifts%rowtype;
  source_lot public.source_lots%rowtype;
  default_product_id uuid;
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

  select id into default_product_id
  from public.products
  where code = 'MALAI_PANEER' and active;
  if default_product_id is null then raise exception 'D paneer product is not configured'; end if;

  select coalesce(max(round_number), 0) + 1 into next_round
  from public.production_batches
  where shift_id = requested_shift_id;

  internal_batch_code := to_char(
      source_lot.received_at at time zone 'Africa/Johannesburg',
      'DDMMYY'
    )
    || '-S' || lpad(target_shift.shift_number::text, 2, '0')
    || '-R' || lpad(next_round::text, 2, '0')
    || '-' || upper(substr(replace(source_lot.id::text, '-', ''), 1, 4));

  insert into public.production_batches (
    id, batch_code, parent_source_lot_id, shift_id, round_number,
    product_id, status, process_stage, process_stage_changed_at,
    started_at, created_by, updated_by
  ) values (
    generated_batch_id, internal_batch_code, target_shift.source_lot_id,
    target_shift.id, next_round, default_product_id, 'in_production',
    'vat_1', now(), now(), auth.uid(), auth.uid()
  );

  return generated_batch_id;
end;
$$;

create or replace function public.update_live_production_round_cell(
  requested_batch_id uuid,
  requested_field text,
  requested_value text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  selected_product_id uuid;
  selected_stage public.paneer_process_stage;
  selected_cut_format public.paneer_cut_format;
  selected_temperature numeric;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;

  if requested_field = 'type' then
    if requested_value not in ('D', 'C/S') then raise exception 'Type must be D or C/S'; end if;
    if target_batch.cut_completed_at is not null or exists (
      select 1 from public.production_round_packing_entries
      where production_batch_id = target_batch.id
    ) then raise exception 'Type cannot change after cutting or packing'; end if;
    select id into selected_product_id
    from public.products
    where variant = requested_value and family_id = (
      select id from public.product_families where code = 'PANEER'
    ) and active
    limit 1;
    if selected_product_id is null then raise exception 'Selected paneer type is unavailable'; end if;
    update public.production_batches set product_id = selected_product_id
    where id = target_batch.id;
  elsif requested_field = 'milk_temperature' then
    selected_temperature := nullif(trim(coalesce(requested_value, '')), '')::numeric;
    if selected_temperature is not null
      and (selected_temperature < -10 or selected_temperature > 110) then
      raise exception 'Milk temperature must be between -10 and 110°C';
    end if;
    update public.production_batches set milk_start_temperature_c = selected_temperature
    where id = target_batch.id;
  elsif requested_field = 'process_stage' then
    if target_batch.cut_completed_at is not null or exists (
      select 1 from public.production_round_packing_entries
      where production_batch_id = target_batch.id
    ) then raise exception 'The process stage cannot change after cutting or packing'; end if;
    selected_stage := requested_value::public.paneer_process_stage;
    update public.production_batches
    set
      process_stage = selected_stage,
      status = case
        when selected_stage = 'presses'::public.paneer_process_stage
          then 'pressing'::public.production_status
        when selected_stage = 'ready_for_cutting'::public.paneer_process_stage
          then 'ready_for_cutting'::public.production_status
        else 'in_production'::public.production_status
      end
    where id = target_batch.id;
  elsif requested_field = 'cut_by' then
    if exists (
      select 1 from public.production_round_packing_entries
      where production_batch_id = target_batch.id
    ) and nullif(trim(coalesce(requested_value, '')), '') is distinct from target_batch.cut_by then
      raise exception 'Cutting details cannot change after packing is recorded';
    end if;
    if length(trim(coalesce(requested_value, ''))) > 0
      and target_batch.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
      raise exception 'The round must be ready for cutting first';
    end if;
    update public.production_batches
    set
      cut_by = nullif(trim(requested_value), ''),
      cut_completed_at = case
        when length(trim(coalesce(requested_value, ''))) > 0 and cut_format is not null
          then coalesce(cut_completed_at, now()) else null end,
      status = case
        when length(trim(coalesce(requested_value, ''))) > 0 and cut_format is not null
          then 'cut'::public.production_status
        else 'ready_for_cutting'::public.production_status end
    where id = target_batch.id;
  elsif requested_field = 'cut_format' then
    if exists (
      select 1 from public.production_round_packing_entries
      where production_batch_id = target_batch.id
    ) and nullif(trim(coalesce(requested_value, '')), '')::public.paneer_cut_format
      is distinct from target_batch.cut_format then
      raise exception 'Cutting details cannot change after packing is recorded';
    end if;
    if length(trim(coalesce(requested_value, ''))) > 0
      and target_batch.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
      raise exception 'The round must be ready for cutting first';
    end if;
    selected_cut_format := nullif(trim(coalesce(requested_value, '')), '')::public.paneer_cut_format;
    update public.production_batches
    set
      cut_format = selected_cut_format,
      cutting_allocation = case selected_cut_format
        when 'cubes_200g'::public.paneer_cut_format then '200 g cubes'
        when 'cubes_400g'::public.paneer_cut_format then '400 g cubes'
        when 'spp'::public.paneer_cut_format then 'SPP'
        when 'restaurant_blocks'::public.paneer_cut_format then 'Restaurant blocks'
        else null end,
      cut_completed_at = case
        when selected_cut_format is not null and length(trim(coalesce(cut_by, ''))) > 0
          then coalesce(cut_completed_at, now()) else null end,
      status = case
        when selected_cut_format is not null and length(trim(coalesce(cut_by, ''))) > 0
          then 'cut'::public.production_status
        else 'ready_for_cutting'::public.production_status end
    where id = target_batch.id;
  else
    raise exception 'Unsupported production-board field';
  end if;

  select * into target_batch from public.production_batches where id = requested_batch_id;
  return jsonb_build_object(
    'id', target_batch.id,
    'product_id', target_batch.product_id,
    'milk_start_temperature_c', target_batch.milk_start_temperature_c,
    'process_stage', target_batch.process_stage,
    'process_stage_changed_at', target_batch.process_stage_changed_at,
    'cut_by', target_batch.cut_by,
    'cut_format', target_batch.cut_format,
    'cut_completed_at', target_batch.cut_completed_at,
    'status', target_batch.status
  );
end;
$$;

create or replace function public.add_production_round_packing_entry(
  requested_batch_id uuid,
  requested_sku_id uuid,
  requested_cases integer,
  requested_loose_packets integer
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  sku_product_id uuid;
  generated_entry_id uuid;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.cut_completed_at is null then
    raise exception 'Record Cut by and Cut into before packing';
  end if;
  if target_batch.cut_format = 'spp'::public.paneer_cut_format then
    raise exception 'SPP must complete crumbing and frying before packing';
  end if;
  if coalesce(requested_cases, 0) < 0 or coalesce(requested_loose_packets, 0) < 0
    or coalesce(requested_cases, 0) + coalesce(requested_loose_packets, 0) = 0 then
    raise exception 'Enter at least one case or loose packet';
  end if;

  select product_id into sku_product_id from public.skus
  where id = requested_sku_id and active;
  if not found or sku_product_id <> target_batch.product_id then
    raise exception 'Select a SKU compatible with the round type';
  end if;

  insert into public.production_round_packing_entries (
    production_batch_id, sku_id, cases, loose_packets, created_by
  ) values (
    target_batch.id, requested_sku_id, coalesce(requested_cases, 0),
    coalesce(requested_loose_packets, 0), auth.uid()
  ) returning id into generated_entry_id;

  return generated_entry_id;
end;
$$;

alter table public.production_batch_stage_events enable row level security;
alter table public.production_round_packing_entries enable row level security;
create policy production_batch_stage_events_select
on public.production_batch_stage_events for select to authenticated
using (public.current_user_role() is not null);
create policy production_round_packing_entries_select
on public.production_round_packing_entries for select to authenticated
using (public.current_user_role() is not null);
grant select on public.production_batch_stage_events,
  public.production_round_packing_entries to authenticated;
revoke insert, update, delete on public.production_batch_stage_events,
  public.production_round_packing_entries from anon, authenticated;

create trigger production_batch_stage_events_audit
after insert or update or delete on public.production_batch_stage_events
for each row execute function public.audit_row_change();
create trigger production_round_packing_entries_audit
after insert or update or delete on public.production_round_packing_entries
for each row execute function public.audit_row_change();

revoke all on function public.add_live_production_round(uuid) from public;
revoke all on function public.update_live_production_round_cell(uuid, text, text) from public;
revoke all on function public.add_production_round_packing_entry(uuid, uuid, integer, integer)
from public;
grant execute on function public.add_live_production_round(uuid) to authenticated;
grant execute on function public.update_live_production_round_cell(uuid, text, text)
to authenticated;
grant execute on function public.add_production_round_packing_entry(uuid, uuid, integer, integer)
to authenticated;

commit;
