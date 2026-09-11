begin;

create table public.production_sku_packing_verifications (
  id uuid primary key default gen_random_uuid(),
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

create table public.production_sku_packing_verification_sources (
  id uuid primary key default gen_random_uuid(),
  verification_id uuid not null
    references public.production_sku_packing_verifications(id) on delete restrict,
  packing_entry_id uuid not null unique
    references public.production_round_packing_entries(id) on delete restrict,
  production_batch_id uuid not null references public.production_batches(id),
  declared_cases integer not null check (declared_cases >= 0),
  declared_loose_packets integer not null check (declared_loose_packets >= 0),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create index production_sku_packing_verifications_status_idx
on public.production_sku_packing_verifications (status, verified_at desc);
create index production_sku_packing_verification_sources_verification_idx
on public.production_sku_packing_verification_sources (verification_id);
create index production_sku_packing_verification_sources_batch_idx
on public.production_sku_packing_verification_sources (production_batch_id);

-- Preserve any verifications recorded during the short round-based phase.
insert into public.production_sku_packing_verifications (
  id, sku_id, declared_cases, declared_loose_packets, corrected_cases,
  corrected_loose_packets, packets_per_case_used, verified_packet_quantity,
  source_round_uncertain, correction_reason, status, verified_at, verified_by,
  sent_to_distribution_at, sent_to_distribution_by, created_at, created_by,
  updated_at, updated_by
)
select
  old.id, old.sku_id, old.declared_cases, old.declared_loose_packets,
  old.corrected_cases, old.corrected_loose_packets, old.packets_per_case_used,
  old.verified_packet_quantity, old.source_round_uncertain, old.correction_reason,
  old.status, old.verified_at, old.verified_by, old.sent_to_distribution_at,
  old.sent_to_distribution_by, old.created_at, old.created_by, old.updated_at,
  old.updated_by
from public.production_round_packing_verifications old
where old.status = 'sent_to_distribution'::public.round_packing_verification_status;

insert into public.production_sku_packing_verifications (
  sku_id, declared_cases, declared_loose_packets, corrected_cases,
  corrected_loose_packets, packets_per_case_used, verified_packet_quantity,
  source_round_uncertain, correction_reason, status, verified_at, verified_by,
  created_at, created_by, updated_at, updated_by
)
select
  old.sku_id,
  sum(old.declared_cases)::integer,
  sum(old.declared_loose_packets)::integer,
  sum(old.corrected_cases)::integer,
  sum(old.corrected_loose_packets)::integer,
  max(old.packets_per_case_used),
  sum(old.verified_packet_quantity)::integer,
  bool_or(old.source_round_uncertain),
  nullif(string_agg(old.correction_reason, '; ' order by old.verified_at)
    filter (where old.correction_reason is not null), ''),
  'verified'::public.round_packing_verification_status,
  max(old.verified_at),
  (array_agg(old.verified_by order by old.verified_at desc))[1],
  min(old.created_at),
  (array_agg(old.created_by order by old.created_at))[1],
  max(old.updated_at),
  (array_agg(old.updated_by order by old.updated_at desc))[1]
from public.production_round_packing_verifications old
where old.status = 'verified'::public.round_packing_verification_status
group by old.sku_id;

insert into public.production_sku_packing_verification_sources (
  verification_id, packing_entry_id, production_batch_id,
  declared_cases, declared_loose_packets, created_by
)
select
  sku_verification.id, entry.id, entry.production_batch_id,
  entry.cases, entry.loose_packets, old.created_by
from public.production_round_packing_verifications old
join public.production_round_packing_entries entry
  on entry.production_batch_id = old.production_batch_id
  and entry.sku_id = old.sku_id
join public.production_sku_packing_verifications sku_verification
  on sku_verification.sku_id = old.sku_id
  and (
    (old.status = 'sent_to_distribution'::public.round_packing_verification_status
      and sku_verification.id = old.id)
    or
    (old.status = 'verified'::public.round_packing_verification_status
      and sku_verification.status = 'verified'::public.round_packing_verification_status)
  );

create unique index production_sku_packing_one_active_per_sku_idx
on public.production_sku_packing_verifications (sku_id)
where status = 'verified'::public.round_packing_verification_status;

alter table public.production_sku_packing_verifications enable row level security;
alter table public.production_sku_packing_verification_sources enable row level security;

create policy production_sku_packing_verifications_select
on public.production_sku_packing_verifications for select to authenticated
using (public.current_user_role() is not null);
create policy production_sku_packing_verification_sources_select
on public.production_sku_packing_verification_sources for select to authenticated
using (public.current_user_role() is not null);

grant select on public.production_sku_packing_verifications,
  public.production_sku_packing_verification_sources to authenticated;
revoke insert, update, delete on public.production_sku_packing_verifications,
  public.production_sku_packing_verification_sources from anon, authenticated;

create trigger production_sku_packing_verifications_set_update_metadata
before update on public.production_sku_packing_verifications
for each row execute function public.set_profile_update_metadata();
create trigger production_sku_packing_verifications_audit
after insert or update or delete on public.production_sku_packing_verifications
for each row execute function public.audit_row_change();
create trigger production_sku_packing_verification_sources_audit
after insert or update or delete on public.production_sku_packing_verification_sources
for each row execute function public.audit_row_change();

drop trigger if exists production_round_packing_entries_prevent_after_verification
on public.production_round_packing_entries;

create or replace function public.serialize_packing_entry_with_sku_verification()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('packing-sku:' || new.sku_id::text, 0)
  );
  return new;
end;
$$;

create trigger production_round_packing_entries_serialize_sku_verification
before insert on public.production_round_packing_entries
for each row execute function public.serialize_packing_entry_with_sku_verification();

create or replace function public.verify_production_sku_packing(
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
  eligible_entry_count integer;
  packet_case_count integer;
  corrected_packet_total integer;
  previous_packet_total integer := 0;
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

  select id, verified_packet_quantity
  into verification_id, previous_packet_total
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
    where id = verification_id;
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
    ) returning id into verification_id;
  end if;

  delete from public.production_sku_packing_verification_sources
  where verification_id = verify_production_sku_packing.verification_id;

  insert into public.production_sku_packing_verification_sources (
    verification_id, packing_entry_id, production_batch_id,
    declared_cases, declared_loose_packets, created_by
  )
  select
    verification_id, entry.id, entry.production_batch_id,
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
      'production_sku_packing_verifications', verification_id,
      'physical_packing_count',
      jsonb_build_object(
        'declared_cases', declared_case_total,
        'declared_loose_packets', declared_loose_total,
        'corrected_cases', requested_corrected_cases,
        'corrected_loose_packets', requested_corrected_loose_packets,
        'source_round_uncertain', coalesce(requested_source_round_uncertain, false),
        'packing_entry_count', eligible_entry_count
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
      verification_id, now(), auth.uid()
    );
  end if;

  return verification_id;
end;
$$;

create or replace function public.send_verified_sku_packing_to_distribution(
  requested_verification_id uuid
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
  if verification.verified_packet_quantity <= 0 then
    raise exception 'There is no verified physical stock to send';
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
    'sku_packing_verification', verification.id, now(), auth.uid()
  );

  update public.production_sku_packing_verifications
  set
    status = 'sent_to_distribution',
    sent_to_distribution_at = now(),
    sent_to_distribution_by = auth.uid(),
    updated_by = auth.uid()
  where id = verification.id;
end;
$$;

revoke execute on function public.verify_production_round_packing(
  uuid, uuid, integer, integer, boolean, text
) from authenticated;
revoke execute on function public.send_verified_packing_to_distribution(uuid)
from authenticated;

revoke all on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text
) from public, anon;
grant execute on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text
) to authenticated;
revoke all on function public.send_verified_sku_packing_to_distribution(uuid)
from public, anon;
grant execute on function public.send_verified_sku_packing_to_distribution(uuid)
to authenticated;

commit;
