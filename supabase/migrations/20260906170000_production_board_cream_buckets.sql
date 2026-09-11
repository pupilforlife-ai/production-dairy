begin;

update public.storage_locations
set name = 'Dairy Container'
where code = 'INTERMEDIATE_FREEZER'
  and name <> 'Dairy Container';

create table public.production_round_cream_buckets (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  bucket_number integer not null check (bucket_number > 0),
  weight_kg numeric not null check (weight_kg > 0),
  intermediate_lot_id uuid not null unique references public.intermediate_lots(id),
  production_batch_output_id uuid not null unique references public.production_batch_outputs(id),
  movement_id uuid not null unique references public.intermediate_lot_movements(id),
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  unique (production_batch_id, bucket_number)
);

create index production_round_cream_buckets_batch_idx
on public.production_round_cream_buckets (production_batch_id, bucket_number);

create or replace function public.validate_recovered_cream_source()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  recovered_product_id uuid;
  source_variant text;
begin
  select id into recovered_product_id
  from public.products
  where code = 'RECOVERED_CREAM';

  if new.output_type = 'recovered' and new.product_id = recovered_product_id then
    select product.variant into source_variant
    from public.production_batches batch
    join public.products product on product.id = batch.product_id
    where batch.id = new.batch_id;

    if source_variant is distinct from 'C/S' then
      raise exception 'Recovered cream can only be recorded from a C/S paneer round';
    end if;
  end if;
  return new;
end;
$$;

create trigger production_batch_outputs_validate_recovered_cream
before insert or update on public.production_batch_outputs
for each row execute function public.validate_recovered_cream_source();

create or replace function public.prevent_round_type_change_with_cream()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.product_id is distinct from old.product_id and exists (
    select 1
    from public.production_round_cream_buckets
    where production_batch_id = old.id
  ) then
    raise exception 'Paneer type cannot change after cream buckets have been recorded';
  end if;
  return new;
end;
$$;

create trigger production_batches_protect_cream_source_type
before update on public.production_batches
for each row execute function public.prevent_round_type_change_with_cream();

create or replace function public.add_production_round_cream_bucket(
  requested_batch_id uuid,
  requested_weight_kg numeric
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  shift_is_open boolean;
  source_variant text;
  recovered_product_id uuid;
  kilogram_id uuid;
  dairy_container_id uuid;
  next_bucket integer;
  generated_bucket_id uuid := gen_random_uuid();
  generated_lot_id uuid := gen_random_uuid();
  generated_output_id uuid := gen_random_uuid();
  generated_movement_id uuid := gen_random_uuid();
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_weight_kg is null or requested_weight_kg <= 0 then
    raise exception 'Cream bucket weight must be greater than zero';
  end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then raise exception 'A locked round cannot be changed'; end if;

  select shift.status = 'open'::public.shift_status
  into shift_is_open
  from public.production_shifts shift
  where shift.id = target_batch.shift_id;
  if not coalesce(shift_is_open, false) then
    raise exception 'Cream buckets can only be recorded before the shift ends';
  end if;

  select variant into source_variant
  from public.products
  where id = target_batch.product_id;
  if source_variant is distinct from 'C/S' then
    raise exception 'Cream buckets can only be recorded for C/S rounds';
  end if;

  select id into recovered_product_id from public.products where code = 'RECOVERED_CREAM';
  select id into kilogram_id from public.units_of_measure where code = 'kg';
  select id into dairy_container_id
  from public.storage_locations
  where code = 'INTERMEDIATE_FREEZER' and active;
  if recovered_product_id is null or kilogram_id is null then
    raise exception 'Recovered cream or kilogram master data is not configured';
  end if;
  if dairy_container_id is null then
    raise exception 'The Dairy Container storage location is unavailable';
  end if;

  select coalesce(max(bucket_number), 0) + 1
  into next_bucket
  from public.production_round_cream_buckets
  where production_batch_id = target_batch.id;

  insert into public.intermediate_lots (
    id, product_id, source_batch_id, lot_code, display_label,
    produced_quantity, current_quantity, uom_id, storage_location_id,
    status, produced_at, created_by, updated_by
  ) values (
    generated_lot_id, recovered_product_id, target_batch.id,
    target_batch.batch_code || '-RC-B' || lpad(next_bucket::text, 2, '0'),
    'Recovered cream bucket ' || next_bucket,
    requested_weight_kg, requested_weight_kg, kilogram_id,
    dairy_container_id, 'available', now(), auth.uid(), auth.uid()
  );

  insert into public.production_batch_outputs (
    id, batch_id, product_id, quantity, uom_id, output_type,
    destination_location_id, generated_intermediate_lot_id, created_by
  ) values (
    generated_output_id, target_batch.id, recovered_product_id,
    requested_weight_kg, kilogram_id, 'recovered',
    dairy_container_id, generated_lot_id, auth.uid()
  );

  insert into public.intermediate_lot_movements (
    id, intermediate_lot_id, movement_type, quantity, uom_id,
    to_location_id, reference, occurred_at, created_by
  ) values (
    generated_movement_id, generated_lot_id, 'production_output',
    requested_weight_kg, kilogram_id, dairy_container_id,
    'Recovered cream bucket ' || next_bucket || ' from ' || target_batch.batch_code,
    now(), auth.uid()
  );

  insert into public.production_round_cream_buckets (
    id, production_batch_id, bucket_number, weight_kg,
    intermediate_lot_id, production_batch_output_id, movement_id,
    recorded_by, updated_by
  ) values (
    generated_bucket_id, target_batch.id, next_bucket, requested_weight_kg,
    generated_lot_id, generated_output_id, generated_movement_id,
    auth.uid(), auth.uid()
  );

  return generated_bucket_id;
end;
$$;

create or replace function public.update_production_round_cream_bucket_weight(
  requested_bucket_id uuid,
  requested_weight_kg numeric
)
returns numeric
language plpgsql security definer set search_path = ''
as $$
declare
  target_bucket public.production_round_cream_buckets%rowtype;
  target_lot public.intermediate_lots%rowtype;
  shift_is_open boolean;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  if requested_weight_kg is null or requested_weight_kg <= 0 then
    raise exception 'Cream bucket weight must be greater than zero';
  end if;

  select * into target_bucket
  from public.production_round_cream_buckets
  where id = requested_bucket_id
  for update;
  if not found then raise exception 'Cream bucket does not exist'; end if;

  select shift.status = 'open'::public.shift_status
  into shift_is_open
  from public.production_batches batch
  join public.production_shifts shift on shift.id = batch.shift_id
  where batch.id = target_bucket.production_batch_id
    and batch.locked_at is null;
  if not coalesce(shift_is_open, false) then
    raise exception 'Cream bucket weights can only be corrected before the shift ends';
  end if;

  select * into target_lot
  from public.intermediate_lots
  where id = target_bucket.intermediate_lot_id
  for update;
  if target_lot.status <> 'available'::public.intermediate_lot_status
    or target_lot.current_quantity <> target_lot.produced_quantity then
    raise exception 'This cream bucket has already been used and cannot be corrected here';
  end if;

  update public.intermediate_lots
  set produced_quantity = requested_weight_kg,
      current_quantity = requested_weight_kg
  where id = target_lot.id;

  update public.production_batch_outputs
  set quantity = requested_weight_kg
  where id = target_bucket.production_batch_output_id;

  update public.intermediate_lot_movements
  set quantity = requested_weight_kg
  where id = target_bucket.movement_id;

  update public.production_round_cream_buckets
  set weight_kg = requested_weight_kg
  where id = target_bucket.id;

  return requested_weight_kg;
end;
$$;

alter table public.production_round_cream_buckets enable row level security;
create policy production_round_cream_buckets_select
on public.production_round_cream_buckets for select to authenticated
using (public.current_user_role() is not null);
grant select on public.production_round_cream_buckets to authenticated;
revoke insert, update, delete on public.production_round_cream_buckets from anon, authenticated;

create trigger production_round_cream_buckets_set_update_metadata
before update on public.production_round_cream_buckets
for each row execute function public.set_profile_update_metadata();
create trigger production_round_cream_buckets_audit
after insert or update or delete on public.production_round_cream_buckets
for each row execute function public.audit_row_change();

revoke all on function public.add_production_round_cream_bucket(uuid, numeric) from public;
revoke all on function public.update_production_round_cream_bucket_weight(uuid, numeric)
from public;
grant execute on function public.add_production_round_cream_bucket(uuid, numeric)
to authenticated;
grant execute on function public.update_production_round_cream_bucket_weight(uuid, numeric)
to authenticated;

commit;
