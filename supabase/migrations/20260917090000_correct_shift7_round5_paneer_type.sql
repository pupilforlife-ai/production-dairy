begin;

-- Staff confirmed that shift 7, round 5 was physically made as C/S paneer.
-- Preserve the three historical ingredient movements: they represent stock
-- already consumed, and reversing them would overstate inventory.
do $$
declare
  target public.production_batches%rowtype;
begin
  select b.* into target
  from public.production_batches b
  join public.production_shifts s on s.id = b.shift_id
  join public.products p on p.id = b.product_id
  where b.id = '724550b8-8b7f-43e3-8e4d-48efc323e616'
    and s.shift_number = 7
    and b.round_number = 5
    and b.batch_code = '130926-S07-R05-D70C'
    and p.code = 'MALAI_PANEER'
    and p.variant = 'D'
  for update of b;

  if not found then
    raise exception 'S7/R5 no longer matches the reviewed D record';
  end if;

  if exists (select 1 from public.production_round_cream_buckets where production_batch_id = target.id)
     or exists (select 1 from public.production_round_blocks where production_batch_id = target.id)
     or exists (select 1 from public.production_round_packing_entries where production_batch_id = target.id) then
    raise exception 'S7/R5 has downstream output; review correction again';
  end if;

  if (select count(*) from public.production_round_ingredient_issues where production_batch_id = target.id) <> 3 then
    raise exception 'S7/R5 ingredient issue count changed; review correction again';
  end if;
end;
$$;

-- The regular protection is intentionally bypassed for this reviewed
-- correction only. The batch and ingredient audit triggers stay active.
alter table public.production_batches disable trigger production_batches_protect_ingredient_issue_type;

update public.production_batches
set product_id = '76db3463-73d1-411d-8346-f09b5340fed5',
    notes = concat_ws(E'\n', nullif(notes, ''),
      '2026-09-17 correction: S7/R5 was physically C/S, entered as D. Existing ingredient consumption retained for stock and audit traceability.')
where id = '724550b8-8b7f-43e3-8e4d-48efc323e616';

alter table public.production_batches enable trigger production_batches_protect_ingredient_issue_type;

do $$
begin
  if not exists (
    select 1
    from public.production_batches b
    join public.products p on p.id = b.product_id
    where b.id = '724550b8-8b7f-43e3-8e4d-48efc323e616'
      and p.variant = 'C/S'
      and b.recipe_version_id is null
  ) then
    raise exception 'S7/R5 C/S correction did not apply as expected';
  end if;
end;
$$;

commit;
