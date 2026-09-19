-- Record privileged corrections to staff-entered final packing SKUs before verification.
create table public.production_round_packing_corrections (
  id uuid primary key default gen_random_uuid(),
  packing_entry_id uuid not null references public.production_round_packing_entries(id),
  production_batch_id uuid not null references public.production_batches(id),
  old_sku_id uuid not null references public.skus(id),
  new_sku_id uuid not null references public.skus(id),
  old_cases integer not null,
  new_cases integer not null,
  old_loose_packets integer not null,
  new_loose_packets integer not null,
  reason text not null check (length(btrim(reason)) between 5 and 500),
  corrected_at timestamptz not null default now(),
  corrected_by uuid not null references auth.users(id)
);

create index production_round_packing_corrections_entry_idx
on public.production_round_packing_corrections (packing_entry_id, corrected_at desc);

alter table public.production_round_packing_corrections enable row level security;
create policy production_round_packing_corrections_select
on public.production_round_packing_corrections for select to authenticated
using (public.current_user_role() in ('owner'::public.app_role, 'admin'::public.app_role));
grant select on public.production_round_packing_corrections to authenticated;
revoke insert, update, delete on public.production_round_packing_corrections from anon, authenticated;

create or replace function public.correct_production_round_packing_entry(
  requested_entry_id uuid,
  requested_sku_id uuid,
  requested_cases integer,
  requested_loose_packets integer,
  requested_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target_entry public.production_round_packing_entries%rowtype;
  target_batch public.production_batches%rowtype;
  target_sku_product_id uuid;
  lock_sku_id uuid;
  original_sku_id uuid;
begin
  if not coalesce(
    public.current_user_role() in ('owner'::public.app_role, 'admin'::public.app_role),
    false
  ) then
    raise exception 'Only an owner or supervisor can correct final SKUs';
  end if;
  if requested_entry_id is null or requested_sku_id is null then
    raise exception 'Select a packing entry and final SKU';
  end if;
  if requested_cases is null or requested_loose_packets is null
     or requested_cases < 0 or requested_loose_packets < 0
     or requested_cases + requested_loose_packets = 0 then
    raise exception 'Enter at least one case or loose packet using nonnegative whole numbers';
  end if;
  if length(btrim(coalesce(requested_reason, ''))) not between 5 and 500 then
    raise exception 'Enter a correction reason of 5 to 500 characters';
  end if;

  select * into target_entry
  from public.production_round_packing_entries
  where id = requested_entry_id;
  if not found then raise exception 'Packing entry does not exist'; end if;
  original_sku_id := target_entry.sku_id;

  -- Verification takes the same per-SKU advisory lock before reading entries.
  for lock_sku_id in
    select distinct sku_id
    from (values (target_entry.sku_id), (requested_sku_id)) as sku_ids(sku_id)
    order by sku_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('packing-sku:' || lock_sku_id::text, 0)
    );
  end loop;

  select * into target_entry
  from public.production_round_packing_entries
  where id = requested_entry_id
  for update;
  if target_entry.sku_id <> original_sku_id then
    raise exception 'Packing entry changed while opening the correction; reload and try again';
  end if;
  select * into target_batch
  from public.production_batches
  where id = target_entry.production_batch_id
  for update;
  if target_batch.locked_at is not null or target_batch.status = 'cancelled' then
    raise exception 'A locked or cancelled production round cannot be corrected';
  end if;
  if exists (
    select 1 from public.production_sku_packing_verification_sources
    where packing_entry_id = target_entry.id
  ) then
    raise exception 'This entry has packing verification history and cannot be changed here';
  end if;

  select product_id into target_sku_product_id
  from public.skus where id = requested_sku_id and active;
  if not found or target_sku_product_id <> target_batch.product_id then
    raise exception 'Select an active SKU compatible with the round product';
  end if;
  if target_entry.sku_id = requested_sku_id
     and target_entry.cases = requested_cases
     and target_entry.loose_packets = requested_loose_packets then
    raise exception 'Change the SKU or packing quantities before saving';
  end if;

  update public.production_round_packing_entries
  set sku_id = requested_sku_id,
      cases = requested_cases,
      loose_packets = requested_loose_packets
  where id = target_entry.id;

  insert into public.production_round_packing_corrections (
    packing_entry_id, production_batch_id, old_sku_id, new_sku_id,
    old_cases, new_cases, old_loose_packets, new_loose_packets,
    reason, corrected_by
  ) values (
    target_entry.id, target_entry.production_batch_id, target_entry.sku_id, requested_sku_id,
    target_entry.cases, requested_cases, target_entry.loose_packets, requested_loose_packets,
    btrim(requested_reason), auth.uid()
  );
end;
$$;

revoke all on function public.correct_production_round_packing_entry(uuid, uuid, integer, integer, text) from public;
grant execute on function public.correct_production_round_packing_entry(uuid, uuid, integer, integer, text) to authenticated;
