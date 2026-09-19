alter type public.round_packing_verification_status add value if not exists 'rejected';

begin;

alter table public.production_sku_packing_verifications
  add column if not exists rejected_cases integer not null default 0 check (rejected_cases >= 0),
  add column if not exists rejected_loose_packets integer not null default 0 check (rejected_loose_packets >= 0),
  add column if not exists rejection_reason text;

create or replace function public.send_verified_sku_packing_to_distribution(
  requested_verification_id uuid,
  requested_cases integer,
  requested_loose_packets integer,
  requested_include_loose_packets boolean,
  requested_exception_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  verification public.production_sku_packing_verifications%rowtype;
  packet_uom_id uuid;
  finished_location_id uuid;
  distribution_location_id uuid;
  transfer_cases integer := coalesce(requested_cases, 0);
  transfer_loose integer := coalesce(requested_loose_packets, 0);
  transfer_packets integer;
  remaining_cases integer;
  remaining_loose integer;
begin
  if not public.can_verify_packing() then raise exception 'Only an owner or admin can send packing to distribution'; end if;
  if transfer_cases < 0 or transfer_loose < 0 then raise exception 'Transfer quantities cannot be negative'; end if;
  if not coalesce(requested_include_loose_packets, false) then transfer_loose := 0; end if;
  select * into verification from public.production_sku_packing_verifications where id = requested_verification_id for update;
  if not found then raise exception 'SKU packing verification does not exist'; end if;
  if verification.status <> 'verified'::public.round_packing_verification_status then raise exception 'This verification is no longer open'; end if;
  remaining_cases := verification.corrected_cases - verification.distributed_cases - coalesce(verification.rejected_cases, 0);
  remaining_loose := verification.corrected_loose_packets - verification.distributed_loose_packets - coalesce(verification.rejected_loose_packets, 0);
  if transfer_cases > remaining_cases or transfer_loose > remaining_loose then raise exception 'Transfer exceeds pending verification balance'; end if;
  if transfer_cases = 0 and transfer_loose = 0 then raise exception 'Enter a case or loose quantity to transfer'; end if;
  if transfer_loose > 0 and length(btrim(coalesce(requested_exception_reason, ''))) = 0 then raise exception 'Enter a reason to transfer loose packets'; end if;
  transfer_packets := transfer_cases * coalesce(verification.packets_per_case_used, 0) + transfer_loose;
  select id into packet_uom_id from public.units_of_measure where code = 'packet';
  select id into finished_location_id from public.storage_locations where code = 'FINISHED_PRODUCTION';
  select id into distribution_location_id from public.storage_locations where code = 'DISTRIBUTION_HANDOVER';
  if packet_uom_id is null or finished_location_id is null or distribution_location_id is null then raise exception 'Distribution handover locations are not configured'; end if;
  insert into public.stock_movements (sku_id, source_location_id, destination_location_id, movement_type, quantity, uom_id, reference_type, reference_id, occurred_at, created_by)
  values (verification.sku_id, finished_location_id, distribution_location_id, 'handover', transfer_packets, packet_uom_id, 'sku_packing_verification', verification.id, now(), auth.uid());
  update public.production_sku_packing_verifications
  set distributed_cases = distributed_cases + transfer_cases,
      distributed_loose_packets = distributed_loose_packets + transfer_loose,
      distributed_packet_quantity = distributed_packet_quantity + transfer_packets,
      distribution_exception_reason = concat_ws('; ', distribution_exception_reason, nullif(btrim(requested_exception_reason), '')),
      status = case when distributed_cases + transfer_cases + coalesce(rejected_cases, 0) >= corrected_cases
                        and distributed_loose_packets + transfer_loose + coalesce(rejected_loose_packets, 0) >= corrected_loose_packets
                    then 'sent_to_distribution'::public.round_packing_verification_status else status end,
      sent_to_distribution_at = case when distributed_cases + transfer_cases + coalesce(rejected_cases, 0) >= corrected_cases
                                      and distributed_loose_packets + transfer_loose + coalesce(rejected_loose_packets, 0) >= corrected_loose_packets then now() else sent_to_distribution_at end,
      sent_to_distribution_by = case when distributed_cases + transfer_cases + coalesce(rejected_cases, 0) >= corrected_cases
                                      and distributed_loose_packets + transfer_loose + coalesce(rejected_loose_packets, 0) >= corrected_loose_packets then auth.uid() else sent_to_distribution_by end,
      updated_by = auth.uid()
  where id = verification.id;
end;
$$;

revoke all on function public.send_verified_sku_packing_to_distribution(uuid, integer, integer, boolean, text) from public, anon;
grant execute on function public.send_verified_sku_packing_to_distribution(uuid, integer, integer, boolean, text) to authenticated;

create or replace function public.reject_pending_sku_packing(
  requested_verification_id uuid,
  requested_cases integer,
  requested_loose_packets integer,
  requested_reason text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v public.production_sku_packing_verifications%rowtype;
begin
  if not public.can_verify_packing() then raise exception 'Only an owner or admin can reject packing'; end if;
  select * into v from public.production_sku_packing_verifications where id = requested_verification_id for update;
  if not found or v.status <> 'verified'::public.round_packing_verification_status then raise exception 'This verification is not open'; end if;
  if requested_cases < 0 or requested_loose_packets < 0 or requested_cases > v.corrected_cases - v.distributed_cases - v.rejected_cases or requested_loose_packets > v.corrected_loose_packets - v.distributed_loose_packets - v.rejected_loose_packets or requested_cases + requested_loose_packets = 0 then raise exception 'Rejected quantity must be within the pending balance'; end if;
  if length(btrim(coalesce(requested_reason, ''))) < 5 then raise exception 'A rejection reason is required'; end if;
  update public.production_sku_packing_verifications
  set rejected_cases = rejected_cases + requested_cases,
      rejected_loose_packets = rejected_loose_packets + requested_loose_packets,
      rejection_reason = concat_ws('; ', rejection_reason, btrim(requested_reason)),
      status = case when distributed_cases + rejected_cases + requested_cases >= corrected_cases and distributed_loose_packets + rejected_loose_packets + requested_loose_packets >= corrected_loose_packets then 'rejected'::public.round_packing_verification_status else status end,
      updated_by = auth.uid()
  where id = v.id;
end;
$$;
revoke all on function public.reject_pending_sku_packing(uuid, integer, integer, text) from public, anon;
grant execute on function public.reject_pending_sku_packing(uuid, integer, integer, text) to authenticated;

commit;
