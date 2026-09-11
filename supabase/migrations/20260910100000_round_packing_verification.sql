begin;

create type public.round_packing_verification_status as enum (
  'verified',
  'sent_to_distribution'
);

create table public.production_round_packing_verifications (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  sku_id uuid not null references public.skus(id),
  declared_cases integer not null check (declared_cases >= 0),
  declared_loose_packets integer not null check (declared_loose_packets >= 0),
  corrected_cases integer not null check (corrected_cases >= 0),
  corrected_loose_packets integer not null check (corrected_loose_packets >= 0),
  packets_per_case_used integer check (
    packets_per_case_used is null or packets_per_case_used > 0
  ),
  verified_packet_quantity integer not null check (verified_packet_quantity >= 0),
  source_round_uncertain boolean not null default false,
  correction_reason text,
  status public.round_packing_verification_status not null default 'verified',
  verified_at timestamptz not null default now(),
  verified_by uuid not null default auth.uid() references auth.users(id),
  sent_to_distribution_at timestamptz,
  sent_to_distribution_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  unique (production_batch_id, sku_id),
  check (
    status <> 'sent_to_distribution'::public.round_packing_verification_status
    or (
      sent_to_distribution_at is not null
      and sent_to_distribution_by is not null
      and verified_packet_quantity > 0
    )
  ),
  check (
    not source_round_uncertain
    or length(trim(coalesce(correction_reason, ''))) > 0
  )
);

create index production_round_packing_verifications_status_idx
on public.production_round_packing_verifications (status, verified_at desc);

alter table public.production_round_packing_verifications enable row level security;

create policy production_round_packing_verifications_select
on public.production_round_packing_verifications for select to authenticated
using (public.current_user_role() is not null);

grant select on public.production_round_packing_verifications to authenticated;
revoke insert, update, delete on public.production_round_packing_verifications
from anon, authenticated;

create trigger production_round_packing_verifications_set_update_metadata
before update on public.production_round_packing_verifications
for each row execute function public.set_profile_update_metadata();

create trigger production_round_packing_verifications_audit
after insert or update or delete on public.production_round_packing_verifications
for each row execute function public.audit_row_change();

create or replace function public.can_verify_packing()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    public.current_user_role() in ('owner'::public.app_role, 'admin'::public.app_role),
    false
  );
$$;

revoke all on function public.can_verify_packing() from public;
grant execute on function public.can_verify_packing() to authenticated;

create or replace function public.verify_production_round_packing(
  requested_batch_id uuid,
  requested_sku_id uuid,
  requested_corrected_cases integer,
  requested_corrected_loose_packets integer,
  requested_source_round_uncertain boolean,
  requested_correction_reason text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  declared_case_total integer;
  declared_loose_total integer;
  packet_case_count integer;
  corrected_packet_total integer;
  previous_packet_total integer := 0;
  previous_status public.round_packing_verification_status;
  verification_id uuid;
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

  -- Serialise verification for one round/SKU, including its first verification,
  -- so concurrent requests cannot create duplicate finished-stock movements.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(requested_batch_id::text || ':' || requested_sku_id::text, 0)
  );

  perform entry.id
  from public.production_round_packing_entries entry
  where entry.production_batch_id = requested_batch_id
    and entry.sku_id = requested_sku_id
  order by entry.id
  for update;
  if not found then raise exception 'No board packing entry exists for this round and SKU'; end if;

  select coalesce(sum(entry.cases), 0), coalesce(sum(entry.loose_packets), 0)
  into declared_case_total, declared_loose_total
  from public.production_round_packing_entries entry
  where entry.production_batch_id = requested_batch_id
    and entry.sku_id = requested_sku_id;

  select config.packets_per_case into packet_case_count
  from public.packaging_configs config
  where config.sku_id = requested_sku_id
    and config.effective_from <= current_date
    and (config.effective_to is null or config.effective_to >= current_date)
  order by config.effective_from desc
  limit 1;

  if requested_corrected_cases > 0 and coalesce(packet_case_count, 0) <= 0 then
    raise exception 'Packets per case must be configured before cases can be verified';
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

  select id, verified_packet_quantity, status
  into verification_id, previous_packet_total, previous_status
  from public.production_round_packing_verifications
  where production_batch_id = requested_batch_id
    and sku_id = requested_sku_id
  for update;

  if found and previous_status = 'sent_to_distribution'::public.round_packing_verification_status then
    raise exception 'Packing already sent to distribution cannot be changed';
  end if;

  insert into public.production_round_packing_verifications (
    production_batch_id, sku_id, declared_cases, declared_loose_packets,
    corrected_cases, corrected_loose_packets, packets_per_case_used,
    verified_packet_quantity, source_round_uncertain, correction_reason,
    status, verified_at, verified_by, created_by, updated_by
  ) values (
    requested_batch_id, requested_sku_id, declared_case_total, declared_loose_total,
    requested_corrected_cases, requested_corrected_loose_packets, packet_case_count,
    corrected_packet_total, coalesce(requested_source_round_uncertain, false),
    nullif(trim(requested_correction_reason), ''), 'verified', now(), auth.uid(),
    auth.uid(), auth.uid()
  )
  on conflict (production_batch_id, sku_id) do update
  set
    declared_cases = excluded.declared_cases,
    declared_loose_packets = excluded.declared_loose_packets,
    corrected_cases = excluded.corrected_cases,
    corrected_loose_packets = excluded.corrected_loose_packets,
    packets_per_case_used = excluded.packets_per_case_used,
    verified_packet_quantity = excluded.verified_packet_quantity,
    source_round_uncertain = excluded.source_round_uncertain,
    correction_reason = excluded.correction_reason,
    status = 'verified'::public.round_packing_verification_status,
    verified_at = now(),
    verified_by = auth.uid(),
    updated_by = auth.uid()
  returning id into verification_id;

  if requested_corrected_cases <> declared_case_total
    or requested_corrected_loose_packets <> declared_loose_total
    or coalesce(requested_source_round_uncertain, false) then
    insert into public.corrections (
      entity_type, entity_id, field_or_measure, replacement_value,
      reason, created_by
    ) values (
      'production_round_packing_verifications', verification_id,
      'physical_packing_count',
      jsonb_build_object(
        'declared_cases', declared_case_total,
        'declared_loose_packets', declared_loose_total,
        'corrected_cases', requested_corrected_cases,
        'corrected_loose_packets', requested_corrected_loose_packets,
        'source_round_uncertain', coalesce(requested_source_round_uncertain, false)
      ),
      trim(requested_correction_reason), auth.uid()
    );
  end if;

  select id into packet_uom_id
  from public.units_of_measure where code = 'packet';
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
      case when previous_status is null
        then 'finished_production'
        else 'correction' end,
      abs(packet_difference), packet_uom_id, 'board_packing_verification',
      verification_id, now(), auth.uid()
    );
  end if;

  return verification_id;
end;
$$;

create or replace function public.send_verified_packing_to_distribution(
  requested_verification_id uuid
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  verification public.production_round_packing_verifications%rowtype;
  packet_uom_id uuid;
  finished_location_id uuid;
  distribution_location_id uuid;
begin
  if not public.can_verify_packing() then
    raise exception 'Only an owner or admin can send packing to distribution';
  end if;

  select * into verification
  from public.production_round_packing_verifications
  where id = requested_verification_id
  for update;
  if not found then raise exception 'Packing verification does not exist'; end if;
  if verification.status = 'sent_to_distribution'::public.round_packing_verification_status then
    return;
  end if;
  if verification.verified_packet_quantity <= 0 then
    raise exception 'There is no verified physical stock to send';
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
    'handover', verification.verified_packet_quantity, packet_uom_id,
    'board_packing_verification', verification.id, now(), auth.uid()
  );

  update public.production_round_packing_verifications
  set
    status = 'sent_to_distribution',
    sent_to_distribution_at = now(),
    sent_to_distribution_by = auth.uid(),
    updated_by = auth.uid()
  where id = verification.id;
end;
$$;

create or replace function public.prevent_packing_after_verification()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.production_round_packing_verifications verification
    where verification.production_batch_id = new.production_batch_id
      and verification.sku_id = new.sku_id
  ) then
    raise exception 'This round and SKU have already been verified; update the verification record instead';
  end if;
  return new;
end;
$$;

create trigger production_round_packing_entries_prevent_after_verification
before insert on public.production_round_packing_entries
for each row execute function public.prevent_packing_after_verification();

revoke all on function public.verify_production_round_packing(
  uuid, uuid, integer, integer, boolean, text
) from public, anon;
grant execute on function public.verify_production_round_packing(
  uuid, uuid, integer, integer, boolean, text
) to authenticated;

revoke all on function public.send_verified_packing_to_distribution(uuid)
from public, anon;
grant execute on function public.send_verified_packing_to_distribution(uuid)
to authenticated;

commit;
