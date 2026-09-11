begin;

alter table public.production_sku_packing_verifications
add column consolidated_loose_packets integer not null default 0
  check (consolidated_loose_packets >= 0);

create table public.loose_stock_consolidations (
  id uuid primary key default gen_random_uuid(),
  consolidation_code text not null unique,
  sku_id uuid not null references public.skus(id),
  packets_per_case_used integer not null check (packets_per_case_used > 0),
  input_loose_packets integer not null check (input_loose_packets > 0),
  output_cases integer not null check (output_cases > 0),
  consolidated_at timestamptz not null default now(),
  consolidated_by uuid not null default auth.uid() references auth.users(id),
  sent_to_distribution_at timestamptz not null default now(),
  sent_to_distribution_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  check (input_loose_packets = output_cases * packets_per_case_used)
);

create table public.loose_stock_consolidation_sources (
  id uuid primary key default gen_random_uuid(),
  consolidation_id uuid not null
    references public.loose_stock_consolidations(id) on delete restrict,
  verification_id uuid not null
    references public.production_sku_packing_verifications(id) on delete restrict,
  packet_quantity integer not null check (packet_quantity > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  unique (consolidation_id, verification_id)
);

create index loose_stock_consolidations_sku_idx
on public.loose_stock_consolidations (sku_id, consolidated_at desc);
create index loose_stock_consolidation_sources_verification_idx
on public.loose_stock_consolidation_sources (verification_id);

alter table public.loose_stock_consolidations enable row level security;
alter table public.loose_stock_consolidation_sources enable row level security;

create policy loose_stock_consolidations_select
on public.loose_stock_consolidations for select to authenticated
using (public.current_user_role() is not null);
create policy loose_stock_consolidation_sources_select
on public.loose_stock_consolidation_sources for select to authenticated
using (public.current_user_role() is not null);

grant select on public.loose_stock_consolidations,
  public.loose_stock_consolidation_sources to authenticated;
revoke insert, update, delete on public.loose_stock_consolidations,
  public.loose_stock_consolidation_sources from anon, authenticated;

create trigger loose_stock_consolidations_audit
after insert or update or delete on public.loose_stock_consolidations
for each row execute function public.audit_row_change();
create trigger loose_stock_consolidation_sources_audit
after insert or update or delete on public.loose_stock_consolidation_sources
for each row execute function public.audit_row_change();

create or replace view public.loose_stock_consolidation_pools
with (security_invoker = true)
as
select
  sku.id as sku_id,
  sku.code as sku_code,
  sku.description as sku_description,
  active_config.packets_per_case,
  sum(verification.retained_loose_packets)::integer as available_loose_packets,
  case
    when coalesce(active_config.packets_per_case, 0) > 0
      then floor(
        sum(verification.retained_loose_packets)::numeric
        / active_config.packets_per_case
      )::integer
    else 0
  end as possible_cases,
  case
    when coalesce(active_config.packets_per_case, 0) > 0
      then mod(
        sum(verification.retained_loose_packets)::integer,
        active_config.packets_per_case
      )
    else sum(verification.retained_loose_packets)::integer
  end as remainder_loose_packets,
  min(coalesce(verification.sent_to_distribution_at, verification.verified_at))
    as oldest_retained_at
from public.production_sku_packing_verifications verification
join public.skus sku on sku.id = verification.sku_id
left join lateral (
  select config.packets_per_case
  from public.packaging_configs config
  where config.sku_id = sku.id
    and config.effective_from <= current_date
    and (config.effective_to is null or config.effective_to >= current_date)
  order by config.effective_from desc
  limit 1
) active_config on true
where verification.status = 'sent_to_distribution'::public.round_packing_verification_status
  and verification.retained_loose_packets > 0
group by sku.id, sku.code, sku.description, active_config.packets_per_case;

create or replace view public.loose_stock_consolidation_history
with (security_invoker = true)
as
select
  consolidation.id,
  consolidation.consolidation_code,
  consolidation.sku_id,
  sku.code as sku_code,
  sku.description as sku_description,
  consolidation.packets_per_case_used,
  consolidation.input_loose_packets,
  consolidation.output_cases,
  consolidation.consolidated_at,
  consolidation.sent_to_distribution_at,
  profile.display_name as consolidated_by_name,
  coalesce(
    string_agg(distinct source_lot.lot_code, ', ' order by source_lot.lot_code),
    'Source not identified'
  ) as source_lot_codes
from public.loose_stock_consolidations consolidation
join public.skus sku on sku.id = consolidation.sku_id
left join public.profiles profile on profile.id = consolidation.consolidated_by
left join public.loose_stock_consolidation_sources consolidation_source
  on consolidation_source.consolidation_id = consolidation.id
left join public.production_sku_packing_verification_sources verification_source
  on verification_source.verification_id = consolidation_source.verification_id
left join public.production_batches batch
  on batch.id = verification_source.production_batch_id
left join public.source_lots source_lot
  on source_lot.id = batch.parent_source_lot_id
group by
  consolidation.id,
  sku.code,
  sku.description,
  profile.display_name;

grant select on public.loose_stock_consolidation_pools,
  public.loose_stock_consolidation_history to authenticated;

create or replace function public.consolidate_loose_stock_to_distribution(
  requested_sku_id uuid,
  requested_case_quantity integer
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  sku_code text;
  packet_case_count integer;
  available_loose_packets integer;
  requested_packet_quantity integer;
  packets_still_needed integer;
  packets_from_source integer;
  daily_sequence integer;
  factory_date date := (now() at time zone 'Africa/Johannesburg')::date;
  generated_code text;
  generated_consolidation_id uuid;
  packet_uom_id uuid;
  finished_location_id uuid;
  distribution_location_id uuid;
  source_verification public.production_sku_packing_verifications%rowtype;
begin
  if not public.can_verify_packing() then
    raise exception 'Only an owner or admin can consolidate loose stock';
  end if;
  if coalesce(requested_case_quantity, 0) <= 0 then
    raise exception 'At least one full case must be consolidated';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || requested_sku_id::text, 0)
  );

  select sku.code, active_config.packets_per_case
  into sku_code, packet_case_count
  from public.skus sku
  left join lateral (
    select config.packets_per_case
    from public.packaging_configs config
    where config.sku_id = sku.id
      and config.effective_from <= current_date
      and (config.effective_to is null or config.effective_to >= current_date)
    order by config.effective_from desc
    limit 1
  ) active_config on true
  where sku.id = requested_sku_id
    and sku.active;

  if not found then raise exception 'SKU is unavailable'; end if;
  if coalesce(packet_case_count, 0) <= 0 then
    raise exception 'Packets per case must be configured before consolidating loose stock';
  end if;

  select coalesce(sum(retained_loose_packets), 0)::integer
  into available_loose_packets
  from public.production_sku_packing_verifications
  where sku_id = requested_sku_id
    and status = 'sent_to_distribution'::public.round_packing_verification_status
    and retained_loose_packets > 0;

  requested_packet_quantity := requested_case_quantity * packet_case_count;
  if requested_packet_quantity > available_loose_packets then
    raise exception 'Only % loose packets are available; % are required for % cases',
      available_loose_packets, requested_packet_quantity, requested_case_quantity;
  end if;

  select count(*) + 1 into daily_sequence
  from public.loose_stock_consolidations
  where sku_id = requested_sku_id
    and (consolidated_at at time zone 'Africa/Johannesburg')::date = factory_date;

  generated_code := 'LC-' || sku_code || '-' || to_char(factory_date, 'YYYYMMDD')
    || '-' || lpad(daily_sequence::text, 2, '0');

  insert into public.loose_stock_consolidations (
    consolidation_code, sku_id, packets_per_case_used,
    input_loose_packets, output_cases, consolidated_by, sent_to_distribution_by
  ) values (
    generated_code, requested_sku_id, packet_case_count,
    requested_packet_quantity, requested_case_quantity, auth.uid(), auth.uid()
  ) returning id into generated_consolidation_id;

  packets_still_needed := requested_packet_quantity;
  for source_verification in
    select *
    from public.production_sku_packing_verifications
    where sku_id = requested_sku_id
      and status = 'sent_to_distribution'::public.round_packing_verification_status
      and retained_loose_packets > 0
    order by coalesce(sent_to_distribution_at, verified_at), id
    for update
  loop
    exit when packets_still_needed <= 0;
    packets_from_source := least(
      source_verification.retained_loose_packets,
      packets_still_needed
    );

    insert into public.loose_stock_consolidation_sources (
      consolidation_id, verification_id, packet_quantity, created_by
    ) values (
      generated_consolidation_id,
      source_verification.id,
      packets_from_source,
      auth.uid()
    );

    update public.production_sku_packing_verifications
    set
      retained_loose_packets = retained_loose_packets - packets_from_source,
      consolidated_loose_packets = consolidated_loose_packets + packets_from_source,
      distributed_packet_quantity = distributed_packet_quantity + packets_from_source,
      updated_by = auth.uid()
    where id = source_verification.id;

    packets_still_needed := packets_still_needed - packets_from_source;
  end loop;

  if packets_still_needed <> 0 then
    raise exception 'Unable to allocate every loose packet required for consolidation';
  end if;

  select id into packet_uom_id from public.units_of_measure where code = 'packet';
  select id into finished_location_id
  from public.storage_locations where code = 'FINISHED_PRODUCTION';
  select id into distribution_location_id
  from public.storage_locations where code = 'DISTRIBUTION_HANDOVER';
  if packet_uom_id is null or finished_location_id is null
    or distribution_location_id is null then
    raise exception 'Distribution handover locations are not configured';
  end if;

  insert into public.stock_movements (
    sku_id, source_location_id, destination_location_id,
    movement_type, quantity, uom_id, reference_type,
    reference_id, occurred_at, created_by
  ) values (
    requested_sku_id, finished_location_id, distribution_location_id,
    'handover', requested_packet_quantity, packet_uom_id,
    'loose_stock_consolidation', generated_consolidation_id, now(), auth.uid()
  );

  return generated_consolidation_id;
end;
$$;

revoke all on function public.consolidate_loose_stock_to_distribution(uuid, integer)
from public, anon;
grant execute on function public.consolidate_loose_stock_to_distribution(uuid, integer)
to authenticated;

-- Exercise the real consolidation transaction when eligible live stock exists.
-- PTST2 deliberately rolls back every self-test write and stock movement.
do $self_test$
declare
  owner_id uuid;
  eligible_sku_id uuid;
begin
  select profile.id into owner_id
  from public.profiles profile
  where profile.role = 'owner'::public.app_role and profile.active
  limit 1;

  select pool.sku_id into eligible_sku_id
  from public.loose_stock_consolidation_pools pool
  where pool.possible_cases > 0
  order by pool.sku_id
  limit 1;

  if owner_id is not null and eligible_sku_id is not null then
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    begin
      perform public.consolidate_loose_stock_to_distribution(eligible_sku_id, 1);
      raise exception using errcode = 'PTST2', message = 'rollback loose consolidation self-test';
    exception when sqlstate 'PTST2' then
      null;
    end;
  end if;
end;
$self_test$;

notify pgrst, 'reload schema';

commit;
