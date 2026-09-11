begin;

create or replace function public.verify_production_sku_packing(
  requested_sku_id uuid,
  requested_corrected_cases integer,
  requested_corrected_loose_packets integer,
  requested_source_round_uncertain boolean,
  requested_correction_reason text,
  requested_packets_per_case integer
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  declared_case_total integer;
  declared_loose_total integer;
  eligible_entry_count integer;
  configured_packet_case_count integer;
  variable_case_allowed boolean := false;
  packet_case_count integer;
  corrected_packet_total integer;
  previous_packet_total integer := 0;
  generated_verification_id uuid;
  packet_uom_id uuid;
  finished_location_id uuid;
  packet_difference integer;
begin
  if not public.can_verify_packing() then
    raise exception 'Only an owner or admin can verify packing';
  end if;
  if coalesce(requested_corrected_cases, -1) < 0
    or coalesce(requested_corrected_loose_packets, -1) < 0 then
    raise exception 'Corrected cases and loose packets cannot be negative';
  end if;
  if requested_packets_per_case is not null and requested_packets_per_case <= 0 then
    raise exception 'Packets per case must be a positive whole number';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || requested_sku_id::text, 0)
  );

  perform entry.id
  from public.production_round_packing_entries entry
  where entry.sku_id = requested_sku_id
    and not exists (
      select 1
      from public.production_sku_packing_verification_sources source
      join public.production_sku_packing_verifications sent
        on sent.id = source.verification_id
      where source.packing_entry_id = entry.id
        and sent.status = 'sent_to_distribution'::public.round_packing_verification_status
    )
  order by entry.id
  for update;
  if not found then raise exception 'No unsent board packing exists for this SKU'; end if;

  select count(*)::integer, coalesce(sum(entry.cases), 0)::integer,
    coalesce(sum(entry.loose_packets), 0)::integer
  into eligible_entry_count, declared_case_total, declared_loose_total
  from public.production_round_packing_entries entry
  where entry.sku_id = requested_sku_id
    and not exists (
      select 1
      from public.production_sku_packing_verification_sources source
      join public.production_sku_packing_verifications sent
        on sent.id = source.verification_id
      where source.packing_entry_id = entry.id
        and sent.status = 'sent_to_distribution'::public.round_packing_verification_status
    );

  select config.packets_per_case, config.variable_case_allowed
  into configured_packet_case_count, variable_case_allowed
  from public.packaging_configs config
  where config.sku_id = requested_sku_id
    and config.effective_from <= current_date
    and (config.effective_to is null or config.effective_to >= current_date)
  order by config.effective_from desc
  limit 1;

  if requested_packets_per_case is not null
    and not coalesce(variable_case_allowed, false) then
    raise exception 'This SKU uses the fixed packets-per-case value from master data';
  end if;

  packet_case_count := case
    when coalesce(variable_case_allowed, false) then requested_packets_per_case
    else configured_packet_case_count
  end;

  if requested_corrected_cases > 0 and coalesce(packet_case_count, 0) <= 0 then
    raise exception 'Enter packets per case before cases can be verified';
  end if;

  corrected_packet_total := requested_corrected_cases * coalesce(packet_case_count, 0)
    + requested_corrected_loose_packets;

  if (
    requested_corrected_cases <> declared_case_total
    or requested_corrected_loose_packets <> declared_loose_total
    or coalesce(requested_source_round_uncertain, false)
  ) and length(trim(coalesce(requested_correction_reason, ''))) = 0 then
    raise exception 'A correction reason is required for a variance or uncertain source round';
  end if;

  select id, verified_packet_quantity
  into generated_verification_id, previous_packet_total
  from public.production_sku_packing_verifications
  where sku_id = requested_sku_id
    and status = 'verified'::public.round_packing_verification_status
  for update;

  if found then
    update public.production_sku_packing_verifications
    set
      declared_cases = declared_case_total,
      declared_loose_packets = declared_loose_total,
      corrected_cases = requested_corrected_cases,
      corrected_loose_packets = requested_corrected_loose_packets,
      packets_per_case_used = packet_case_count,
      verified_packet_quantity = corrected_packet_total,
      source_round_uncertain = coalesce(requested_source_round_uncertain, false),
      correction_reason = nullif(trim(requested_correction_reason), ''),
      verified_at = now(),
      verified_by = auth.uid(),
      updated_by = auth.uid()
    where id = generated_verification_id;
  else
    insert into public.production_sku_packing_verifications (
      sku_id, declared_cases, declared_loose_packets, corrected_cases,
      corrected_loose_packets, packets_per_case_used, verified_packet_quantity,
      source_round_uncertain, correction_reason, verified_by, created_by, updated_by
    ) values (
      requested_sku_id, declared_case_total, declared_loose_total,
      requested_corrected_cases, requested_corrected_loose_packets,
      packet_case_count, corrected_packet_total,
      coalesce(requested_source_round_uncertain, false),
      nullif(trim(requested_correction_reason), ''), auth.uid(), auth.uid(), auth.uid()
    ) returning id into generated_verification_id;
  end if;

  delete from public.production_sku_packing_verification_sources verification_source
  where verification_source.verification_id = generated_verification_id;

  insert into public.production_sku_packing_verification_sources (
    verification_id, packing_entry_id, production_batch_id,
    declared_cases, declared_loose_packets, created_by
  )
  select
    generated_verification_id, entry.id, entry.production_batch_id,
    entry.cases, entry.loose_packets, auth.uid()
  from public.production_round_packing_entries entry
  where entry.sku_id = requested_sku_id
    and not exists (
      select 1
      from public.production_sku_packing_verification_sources source
      join public.production_sku_packing_verifications sent
        on sent.id = source.verification_id
      where source.packing_entry_id = entry.id
        and sent.status = 'sent_to_distribution'::public.round_packing_verification_status
    );

  if requested_corrected_cases <> declared_case_total
    or requested_corrected_loose_packets <> declared_loose_total
    or coalesce(requested_source_round_uncertain, false) then
    insert into public.corrections (
      entity_type, entity_id, field_or_measure, replacement_value, reason, created_by
    ) values (
      'production_sku_packing_verifications', generated_verification_id,
      'physical_packing_count',
      jsonb_build_object(
        'declared_cases', declared_case_total,
        'declared_loose_packets', declared_loose_total,
        'corrected_cases', requested_corrected_cases,
        'corrected_loose_packets', requested_corrected_loose_packets,
        'source_round_uncertain', coalesce(requested_source_round_uncertain, false),
        'packing_entry_count', eligible_entry_count,
        'packets_per_case_used', packet_case_count
      ),
      trim(requested_correction_reason), auth.uid()
    );
  end if;

  select id into packet_uom_id from public.units_of_measure where code = 'packet';
  select id into finished_location_id
  from public.storage_locations where code = 'FINISHED_PRODUCTION';
  if packet_uom_id is null or finished_location_id is null then
    raise exception 'Finished-production packet stock is not configured';
  end if;

  packet_difference := corrected_packet_total - coalesce(previous_packet_total, 0);
  if packet_difference <> 0 then
    insert into public.stock_movements (
      sku_id, source_location_id, destination_location_id,
      movement_type, quantity, uom_id, reference_type,
      reference_id, occurred_at, created_by
    ) values (
      requested_sku_id,
      case when packet_difference < 0 then finished_location_id else null end,
      case when packet_difference > 0 then finished_location_id else null end,
      case when previous_packet_total is null
        then 'finished_production' else 'correction' end,
      abs(packet_difference), packet_uom_id, 'sku_packing_verification',
      generated_verification_id, now(), auth.uid()
    );
  end if;

  return generated_verification_id;
end;
$$;

revoke all on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text, integer
) from public, anon;
grant execute on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text, integer
) to authenticated;

commit;
