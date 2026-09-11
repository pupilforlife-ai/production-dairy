begin;

alter table public.production_sku_packing_verifications
  add column distributed_cases integer not null default 0 check (distributed_cases >= 0),
  add column distributed_loose_packets integer not null default 0
    check (distributed_loose_packets >= 0),
  add column distributed_packet_quantity integer not null default 0
    check (distributed_packet_quantity >= 0),
  add column retained_loose_packets integer not null default 0
    check (retained_loose_packets >= 0),
  add column distribution_exception_reason text;

-- Historical handovers predate the full-case-only rule and already transferred
-- the complete verified packet quantity.
update public.production_sku_packing_verifications
set
  distributed_cases = corrected_cases,
  distributed_loose_packets = corrected_loose_packets,
  distributed_packet_quantity = verified_packet_quantity,
  retained_loose_packets = 0,
  distribution_exception_reason = case
    when corrected_loose_packets > 0
      then 'Transferred before the full-case-only distribution rule was introduced'
    else null
  end
where status = 'sent_to_distribution'::public.round_packing_verification_status;

drop function public.send_verified_sku_packing_to_distribution(uuid);

create function public.send_verified_sku_packing_to_distribution(
  requested_verification_id uuid,
  requested_include_loose_packets boolean,
  requested_exception_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  verification public.production_sku_packing_verifications%rowtype;
  target_sku_id uuid;
  packet_uom_id uuid;
  finished_location_id uuid;
  distribution_location_id uuid;
  full_case_packet_quantity integer;
  loose_packet_quantity integer;
  handover_packet_quantity integer;
begin
  if not public.can_verify_packing() then
    raise exception 'Only an owner or admin can send packing to distribution';
  end if;

  select sku_id into target_sku_id
  from public.production_sku_packing_verifications
  where id = requested_verification_id;
  if not found then raise exception 'SKU packing verification does not exist'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || target_sku_id::text, 0)
  );

  select * into verification
  from public.production_sku_packing_verifications
  where id = requested_verification_id
  for update;
  if verification.status = 'sent_to_distribution'::public.round_packing_verification_status then
    return;
  end if;

  if exists (
    select 1
    from public.production_round_packing_entries entry
    where entry.sku_id = verification.sku_id
      and not exists (
        select 1
        from public.production_sku_packing_verification_sources current_source
        where current_source.verification_id = verification.id
          and current_source.packing_entry_id = entry.id
      )
      and not exists (
        select 1
        from public.production_sku_packing_verification_sources old_source
        join public.production_sku_packing_verifications sent
          on sent.id = old_source.verification_id
        where old_source.packing_entry_id = entry.id
          and sent.status = 'sent_to_distribution'::public.round_packing_verification_status
      )
  ) then
    raise exception 'New packing was logged after verification; recheck this SKU before distribution';
  end if;

  full_case_packet_quantity := verification.corrected_cases
    * coalesce(verification.packets_per_case_used, 0);
  loose_packet_quantity := case
    when coalesce(requested_include_loose_packets, false)
      then verification.corrected_loose_packets
    else 0
  end;
  handover_packet_quantity := full_case_packet_quantity + loose_packet_quantity;

  if verification.corrected_cases > 0
    and coalesce(verification.packets_per_case_used, 0) <= 0 then
    raise exception 'Packets per case must be configured before full cases can be distributed';
  end if;
  if coalesce(requested_include_loose_packets, false)
    and verification.corrected_loose_packets > 0
    and length(trim(coalesce(requested_exception_reason, ''))) = 0 then
    raise exception 'A reason is required to send loose packets as an exception';
  end if;
  if handover_packet_quantity <= 0 then
    raise exception 'No complete cases are available; explicitly approve loose packets to continue';
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
    verification.sku_id, finished_location_id, distribution_location_id,
    'handover', handover_packet_quantity, packet_uom_id,
    'sku_packing_verification', verification.id, now(), auth.uid()
  );

  if loose_packet_quantity > 0 then
    insert into public.corrections (
      entity_type, entity_id, field_or_measure, replacement_value, reason, created_by
    ) values (
      'production_sku_packing_verifications', verification.id,
      'distribution_rule_exception',
      jsonb_build_object('loose_packets_sent', loose_packet_quantity),
      trim(requested_exception_reason), auth.uid()
    );
  end if;

  update public.production_sku_packing_verifications
  set
    status = 'sent_to_distribution',
    distributed_cases = corrected_cases,
    distributed_loose_packets = loose_packet_quantity,
    distributed_packet_quantity = handover_packet_quantity,
    retained_loose_packets = corrected_loose_packets - loose_packet_quantity,
    distribution_exception_reason = case when loose_packet_quantity > 0
      then trim(requested_exception_reason) else null end,
    sent_to_distribution_at = now(),
    sent_to_distribution_by = auth.uid(),
    updated_by = auth.uid()
  where id = verification.id;
end;
$$;

create function public.send_retained_sku_loose_to_distribution(
  requested_verification_id uuid,
  requested_exception_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  verification public.production_sku_packing_verifications%rowtype;
  target_sku_id uuid;
  packet_uom_id uuid;
  finished_location_id uuid;
  distribution_location_id uuid;
begin
  if not public.can_verify_packing() then
    raise exception 'Only an owner or admin can release retained loose packets';
  end if;
  if length(trim(coalesce(requested_exception_reason, ''))) = 0 then
    raise exception 'A reason is required to release retained loose packets';
  end if;

  select sku_id into target_sku_id
  from public.production_sku_packing_verifications
  where id = requested_verification_id;
  if not found then raise exception 'SKU packing verification does not exist'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || target_sku_id::text, 0)
  );

  select * into verification
  from public.production_sku_packing_verifications
  where id = requested_verification_id
  for update;
  if verification.status <> 'sent_to_distribution'::public.round_packing_verification_status
    or verification.retained_loose_packets <= 0 then
    raise exception 'This distribution group has no retained loose packets';
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
    verification.sku_id, finished_location_id, distribution_location_id,
    'handover', verification.retained_loose_packets, packet_uom_id,
    'sku_packing_loose_exception', verification.id, now(), auth.uid()
  );

  insert into public.corrections (
    entity_type, entity_id, field_or_measure, replacement_value, reason, created_by
  ) values (
    'production_sku_packing_verifications', verification.id,
    'retained_loose_distribution_exception',
    jsonb_build_object('loose_packets_sent', verification.retained_loose_packets),
    trim(requested_exception_reason), auth.uid()
  );

  update public.production_sku_packing_verifications
  set
    distributed_loose_packets = distributed_loose_packets + retained_loose_packets,
    distributed_packet_quantity = distributed_packet_quantity + retained_loose_packets,
    retained_loose_packets = 0,
    distribution_exception_reason = concat_ws(
      '; ', distribution_exception_reason, trim(requested_exception_reason)
    ),
    updated_by = auth.uid()
  where id = verification.id;
end;
$$;

revoke all on function public.send_verified_sku_packing_to_distribution(
  uuid, boolean, text
) from public, anon;
grant execute on function public.send_verified_sku_packing_to_distribution(
  uuid, boolean, text
) to authenticated;
revoke all on function public.send_retained_sku_loose_to_distribution(uuid, text)
from public, anon;
grant execute on function public.send_retained_sku_loose_to_distribution(uuid, text)
to authenticated;

commit;
