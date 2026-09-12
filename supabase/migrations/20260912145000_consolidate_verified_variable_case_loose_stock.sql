begin;

create or replace view public.loose_stock_consolidation_pools
with (security_invoker = true)
as
select
  retained.sku_id,
  retained.sku_code,
  retained.sku_description,
  retained.packets_per_case,
  sum(retained.retained_loose_packets)::integer as available_loose_packets,
  case
    when coalesce(retained.packets_per_case, 0) > 0
      then floor(
        sum(retained.retained_loose_packets)::numeric
        / retained.packets_per_case
      )::integer
    else 0
  end as possible_cases,
  case
    when coalesce(retained.packets_per_case, 0) > 0
      then mod(
        sum(retained.retained_loose_packets)::integer,
        retained.packets_per_case
      )
    else sum(retained.retained_loose_packets)::integer
  end as remainder_loose_packets,
  min(retained.retained_at) as oldest_retained_at,
  retained.sku_id::text || ':' || coalesce(retained.packets_per_case::text, 'unconfigured')
    as pool_key
from (
  select
    sku.id as sku_id,
    sku.code as sku_code,
    sku.description as sku_description,
    coalesce(active_config.packets_per_case, verification.packets_per_case_used)
      as packets_per_case,
    verification.retained_loose_packets,
    coalesce(verification.sent_to_distribution_at, verification.verified_at)
      as retained_at
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
) retained
group by
  retained.sku_id,
  retained.sku_code,
  retained.sku_description,
  retained.packets_per_case;

grant select on public.loose_stock_consolidation_pools to authenticated;

create or replace function public.consolidate_loose_stock_to_distribution(
  requested_sku_id uuid,
  requested_packets_per_case integer,
  requested_case_quantity integer
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  sku_code text;
  configured_packet_case_count integer;
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
  if requested_packets_per_case is not null and requested_packets_per_case <= 0 then
    raise exception 'Packets per case must be a positive whole number';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || requested_sku_id::text, 0)
  );

  select sku.code, active_config.packets_per_case
  into sku_code, configured_packet_case_count
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

  packet_case_count := coalesce(requested_packets_per_case, configured_packet_case_count);
  if coalesce(packet_case_count, 0) <= 0 then
    raise exception 'Packets per case must be configured before consolidating loose stock';
  end if;

  select coalesce(sum(eligible.retained_loose_packets), 0)::integer
  into available_loose_packets
  from (
    select
      verification.retained_loose_packets,
      coalesce(active_config.packets_per_case, verification.packets_per_case_used)
        as effective_packets_per_case
    from public.production_sku_packing_verifications verification
    left join lateral (
      select config.packets_per_case
      from public.packaging_configs config
      where config.sku_id = verification.sku_id
        and config.effective_from <= current_date
        and (config.effective_to is null or config.effective_to >= current_date)
      order by config.effective_from desc
      limit 1
    ) active_config on true
    where verification.sku_id = requested_sku_id
      and verification.status = 'sent_to_distribution'::public.round_packing_verification_status
      and verification.retained_loose_packets > 0
  ) eligible
  where eligible.effective_packets_per_case = packet_case_count;

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
    select verification.*
    from public.production_sku_packing_verifications verification
    left join lateral (
      select config.packets_per_case
      from public.packaging_configs config
      where config.sku_id = verification.sku_id
        and config.effective_from <= current_date
        and (config.effective_to is null or config.effective_to >= current_date)
      order by config.effective_from desc
      limit 1
    ) active_config on true
    where verification.sku_id = requested_sku_id
      and verification.status = 'sent_to_distribution'::public.round_packing_verification_status
      and verification.retained_loose_packets > 0
      and coalesce(active_config.packets_per_case, verification.packets_per_case_used)
        = packet_case_count
    order by coalesce(verification.sent_to_distribution_at, verification.verified_at), verification.id
    for update of verification
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

revoke all on function public.consolidate_loose_stock_to_distribution(uuid, integer, integer)
from public, anon;
grant execute on function public.consolidate_loose_stock_to_distribution(uuid, integer, integer)
to authenticated;

notify pgrst, 'reload schema';

commit;
