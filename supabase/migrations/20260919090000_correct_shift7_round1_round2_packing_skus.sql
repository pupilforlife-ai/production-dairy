begin;

do $$
declare
  target_batch_id uuid;
  target_entry_id uuid;
  expected_sku_id uuid;
  replacement_sku_id uuid;
  entry_count integer;
  verification_id uuid;
begin
  -- Shift 7, Round 1: RPAN010 was entered instead of RPAN100.
  select b.id into target_batch_id
  from public.production_batches b
  join public.production_shifts s on s.id = b.shift_id
  join public.products p on p.id = b.product_id
  where s.shift_number = 7
    and b.round_number = 1
    and p.code = 'ROZANA_PANEER'
  order by b.created_at
  limit 1;

  if target_batch_id is null then
    raise exception 'Shift 7 Round 1 Rozana batch not found';
  end if;

  select count(*)::integer
  into entry_count
  from public.production_round_packing_entries entry
  where entry.production_batch_id = target_batch_id;

  if entry_count <> 1 then
    raise exception 'Shift 7 Round 1 expected one packing entry, found %', entry_count;
  end if;

  select entry.id into target_entry_id
  from public.production_round_packing_entries entry
  where entry.production_batch_id = target_batch_id;

  select id into expected_sku_id from public.skus where code = 'RPAN010';
  select id into replacement_sku_id from public.skus where code = 'RPAN100';

  if not exists (
    select 1 from public.production_round_packing_entries
    where id = target_entry_id and sku_id = expected_sku_id
  ) then
    raise exception 'Shift 7 Round 1 packing entry is not RPAN010';
  end if;

  select source.verification_id into verification_id
  from public.production_sku_packing_verification_sources source
  where source.packing_entry_id = target_entry_id;

  if verification_id is null then
    raise exception 'Shift 7 Round 1 packing entry has no verification history';
  end if;

  update public.production_round_packing_entries
  set sku_id = replacement_sku_id
  where id = target_entry_id;

  update public.production_sku_packing_verifications
  set sku_id = replacement_sku_id
  where id = verification_id and status = 'sent_to_distribution';

  update public.stock_movements
  set sku_id = replacement_sku_id
  where reference_type = 'sku_packing_verification'
    and reference_id = verification_id;

  -- Shift 7, Round 2: MPAN010 was entered instead of MPAN100.
  select b.id into target_batch_id
  from public.production_batches b
  join public.production_shifts s on s.id = b.shift_id
  join public.products p on p.id = b.product_id
  where s.shift_number = 7
    and b.round_number = 2
    and p.code = 'MALAI_PANEER'
  order by b.created_at
  limit 1;

  if target_batch_id is null then
    raise exception 'Shift 7 Round 2 Malai batch not found';
  end if;

  select count(*)::integer
  into entry_count
  from public.production_round_packing_entries entry
  where entry.production_batch_id = target_batch_id;

  if entry_count <> 2 then
    raise exception 'Shift 7 Round 2 expected two packing entries, found %', entry_count;
  end if;

  select id into expected_sku_id from public.skus where code = 'MPAN010';
  select id into replacement_sku_id from public.skus where code = 'MPAN100';

  if exists (
    select 1 from public.production_round_packing_entries
    where production_batch_id = target_batch_id and sku_id <> expected_sku_id
  ) then
    raise exception 'Shift 7 Round 2 contains a packing entry other than MPAN010';
  end if;

  if exists (
    select 1 from public.production_sku_packing_verification_sources
    where production_batch_id = target_batch_id
  ) then
    raise exception 'Shift 7 Round 2 packing entries already have verification history';
  end if;

  update public.production_round_packing_entries
  set sku_id = replacement_sku_id
  where production_batch_id = target_batch_id and sku_id = expected_sku_id;
end;
$$;

commit;