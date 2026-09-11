begin;

alter table public.production_batches
add column pressed_block_count integer check (
  pressed_block_count is null or pressed_block_count > 0
);

create table public.production_round_blocks (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  block_number integer not null check (block_number > 0),
  weight_kg numeric check (weight_kg is null or weight_kg > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  unique (production_batch_id, block_number)
);

create table public.production_block_anomalies (
  id uuid primary key default gen_random_uuid(),
  production_round_block_id uuid references public.production_round_blocks(id) on delete set null,
  production_batch_id uuid not null references public.production_batches(id),
  block_number integer not null,
  detected_weight_kg numeric not null check (detected_weight_kg > 13),
  anomaly_type text not null default 'above_press_capacity'
    check (anomaly_type = 'above_press_capacity'),
  detected_at timestamptz not null default now(),
  detected_by uuid not null default auth.uid() references auth.users(id)
);

create index production_round_blocks_batch_idx
on public.production_round_blocks (production_batch_id, block_number);
create index production_block_anomalies_batch_idx
on public.production_block_anomalies (production_batch_id, detected_at desc);

create or replace function public.record_pressed_block_anomaly()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.weight_kg > 13 and (
    tg_op = 'INSERT' or new.weight_kg is distinct from old.weight_kg
  ) then
    insert into public.production_block_anomalies (
      production_round_block_id,
      production_batch_id,
      block_number,
      detected_weight_kg,
      detected_by
    ) values (
      new.id,
      new.production_batch_id,
      new.block_number,
      new.weight_kg,
      auth.uid()
    );
  end if;
  return new;
end;
$$;

create trigger production_round_blocks_record_anomaly
after insert or update on public.production_round_blocks
for each row execute function public.record_pressed_block_anomaly();

create or replace function public.require_pressed_block_weights_before_cutting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  recorded_count integer;
  missing_count integer;
begin
  if new.cut_completed_at is null or old.cut_completed_at is not null then return new; end if;
  if new.pressed_block_count is null then
    raise exception 'Record the number of pressed blocks before cutting';
  end if;

  select count(*), count(*) filter (where weight_kg is null)
  into recorded_count, missing_count
  from public.production_round_blocks
  where production_batch_id = new.id;

  if recorded_count <> new.pressed_block_count or missing_count > 0 then
    raise exception 'Record the weight of every pressed block before cutting';
  end if;
  return new;
end;
$$;

create trigger production_batches_require_block_weights
before update on public.production_batches
for each row execute function public.require_pressed_block_weights_before_cutting();

create or replace function public.set_production_round_block_count(
  requested_batch_id uuid,
  requested_block_count integer
)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_block_count is null or requested_block_count <= 0 then
    raise exception 'Number of blocks must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
    raise exception 'Block details are recorded after resting, when the round is ready for cutting';
  end if;
  if target_batch.cut_completed_at is not null or exists (
    select 1 from public.production_round_packing_entries
    where production_batch_id = target_batch.id
  ) then raise exception 'Block details cannot change after cutting or packing'; end if;

  update public.production_batches
  set pressed_block_count = requested_block_count
  where id = target_batch.id;

  insert into public.production_round_blocks (
    production_batch_id, block_number, created_by, updated_by
  )
  select target_batch.id, generated.block_number, auth.uid(), auth.uid()
  from generate_series(1, requested_block_count) as generated(block_number)
  on conflict (production_batch_id, block_number) do nothing;

  delete from public.production_round_blocks
  where production_batch_id = target_batch.id
    and block_number > requested_block_count;

  return requested_block_count;
end;
$$;

create or replace function public.set_production_round_block_weight(
  requested_batch_id uuid,
  requested_block_number integer,
  requested_weight_kg numeric
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  target_block public.production_round_blocks%rowtype;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_weight_kg is null or requested_weight_kg <= 0 then
    raise exception 'Block weight must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;
  if target_batch.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
    raise exception 'Block weights are recorded after resting, when the round is ready for cutting';
  end if;
  if target_batch.cut_completed_at is not null or exists (
    select 1 from public.production_round_packing_entries
    where production_batch_id = target_batch.id
  ) then raise exception 'Block weights cannot change after cutting or packing'; end if;

  select * into target_block
  from public.production_round_blocks
  where production_batch_id = target_batch.id
    and block_number = requested_block_number
  for update;
  if not found then raise exception 'Set the number of blocks before entering weights'; end if;

  update public.production_round_blocks
  set weight_kg = requested_weight_kg
  where id = target_block.id
  returning * into target_block;

  return jsonb_build_object(
    'id', target_block.id,
    'production_batch_id', target_block.production_batch_id,
    'block_number', target_block.block_number,
    'weight_kg', target_block.weight_kg,
    'updated_at', target_block.updated_at
  );
end;
$$;

alter table public.production_round_blocks enable row level security;
alter table public.production_block_anomalies enable row level security;

create policy production_round_blocks_select
on public.production_round_blocks for select to authenticated
using (public.current_user_role() is not null);
create policy production_block_anomalies_select
on public.production_block_anomalies for select to authenticated
using (public.current_user_role() is not null);

grant select on public.production_round_blocks,
  public.production_block_anomalies to authenticated;
revoke insert, update, delete on public.production_round_blocks,
  public.production_block_anomalies from anon, authenticated;

create trigger production_round_blocks_set_update_metadata
before update on public.production_round_blocks
for each row execute function public.set_profile_update_metadata();
create trigger production_round_blocks_audit
after insert or update or delete on public.production_round_blocks
for each row execute function public.audit_row_change();
create trigger production_block_anomalies_audit
after insert or update or delete on public.production_block_anomalies
for each row execute function public.audit_row_change();

revoke all on function public.set_production_round_block_count(uuid, integer) from public;
revoke all on function public.set_production_round_block_weight(uuid, integer, numeric) from public;
grant execute on function public.set_production_round_block_count(uuid, integer) to authenticated;
grant execute on function public.set_production_round_block_weight(uuid, integer, numeric)
to authenticated;

commit;
