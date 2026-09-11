begin;

-- The deployed function used a local variable named verification_id while also
-- updating a table with a verification_id column. Rename only the PL/pgSQL
-- variable and its value references, leaving the real table columns unchanged.
do $patch_function$
declare
  current_definition text;
  patched_definition text;
begin
  select pg_catalog.pg_get_functiondef(procedure.oid)
  into current_definition
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'public'
    and procedure.proname = 'verify_production_sku_packing'
    and pg_catalog.pg_get_function_identity_arguments(procedure.oid)
      = 'requested_sku_id uuid, requested_corrected_cases integer, requested_corrected_loose_packets integer, requested_source_round_uncertain boolean, requested_correction_reason text';

  if current_definition is null then
    raise exception 'verify_production_sku_packing function was not found';
  end if;

  patched_definition := replace(current_definition,
    '  verification_id uuid;', '  target_verification_id uuid;');
  patched_definition := replace(patched_definition,
    '  into verification_id, previous_packet_total',
    '  into target_verification_id, previous_packet_total');
  patched_definition := replace(patched_definition,
    '    where id = verification_id;',
    '    where id = target_verification_id;');
  patched_definition := replace(patched_definition,
    '    ) returning id into verification_id;',
    '    ) returning id into target_verification_id;');
  patched_definition := replace(patched_definition,
    '  where verification_id = verify_production_sku_packing.verification_id;',
    '  where production_sku_packing_verification_sources.verification_id = target_verification_id;');
  patched_definition := replace(patched_definition,
    '    verification_id, entry.id, entry.production_batch_id,',
    '    target_verification_id, entry.id, entry.production_batch_id,');
  patched_definition := replace(patched_definition,
    $$      'production_sku_packing_verifications', verification_id,$$,
    $$      'production_sku_packing_verifications', target_verification_id,$$);
  patched_definition := replace(patched_definition,
    '      verification_id, now(), auth.uid()',
    '      target_verification_id, now(), auth.uid()');
  patched_definition := replace(patched_definition,
    '  return verification_id;', '  return target_verification_id;');

  if position('verify_production_sku_packing.verification_id' in patched_definition) > 0
    or position('  verification_id uuid;' in patched_definition) > 0 then
    raise exception 'Verification function still contains the ambiguous variable';
  end if;
  if position('target_verification_id' in patched_definition) = 0 then
    raise exception 'Unable to rename the verification variable';
  end if;

  execute patched_definition;
end;
$patch_function$;

revoke all on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text
) from public, anon;
grant execute on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text
) to authenticated;

-- Exercise the real RPC against an eligible live SKU inside a subtransaction.
-- The deliberate PTST1 exception rolls back every verification test write.
do $self_test$
declare
  owner_id uuid;
  test_sku_id uuid;
  test_cases integer;
  test_loose_packets integer;
begin
  select profile.id into owner_id
  from public.profiles profile
  where profile.role = 'owner'::public.app_role and profile.active
  limit 1;

  select entry.sku_id, sum(entry.cases)::integer, sum(entry.loose_packets)::integer
  into test_sku_id, test_cases, test_loose_packets
  from public.production_round_packing_entries entry
  join public.packaging_configs config
    on config.sku_id = entry.sku_id
    and config.packets_per_case is not null
    and config.effective_from <= current_date
    and (config.effective_to is null or config.effective_to >= current_date)
  where not exists (
    select 1
    from public.production_sku_packing_verification_sources source
    join public.production_sku_packing_verifications sent
      on sent.id = source.verification_id
    where source.packing_entry_id = entry.id
      and sent.status = 'sent_to_distribution'::public.round_packing_verification_status
  )
  group by entry.sku_id
  order by entry.sku_id
  limit 1;

  if owner_id is not null and test_sku_id is not null then
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    begin
      perform public.verify_production_sku_packing(
        test_sku_id, test_cases, test_loose_packets, false, null
      );
      raise exception using errcode = 'PTST1', message = 'rollback verification self-test';
    exception when sqlstate 'PTST1' then
      null;
    end;
  end if;
end;
$self_test$;

notify pgrst, 'reload schema';

commit;
