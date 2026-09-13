begin;

insert into public.skus (
  product_id,
  code,
  description,
  unit_weight_g,
  pieces_per_packet,
  active
)
select
  product.id,
  'YD200',
  'YD200 malai paneer',
  200,
  null,
  true
from public.products product
where product.code = 'MALAI_PANEER'
on conflict (code) do update
set
  product_id = excluded.product_id,
  description = excluded.description,
  unit_weight_g = excluded.unit_weight_g,
  pieces_per_packet = excluded.pieces_per_packet,
  active = excluded.active,
  updated_at = now(),
  updated_by = auth.uid();

update public.packaging_configs
set
  effective_to = date '2026-09-13',
  updated_at = now(),
  updated_by = auth.uid()
where sku_id = (select id from public.skus where code = 'YD200')
  and effective_from < date '2026-09-14'
  and effective_to is null;

insert into public.packaging_configs (
  sku_id,
  units_per_inner_pack,
  packets_per_case,
  nominal_case_weight_kg,
  variable_case_allowed,
  effective_from,
  effective_to
)
select
  sku.id,
  1,
  36,
  7.2,
  false,
  date '2026-09-14',
  null
from public.skus sku
where sku.code = 'YD200'
on conflict (sku_id, effective_from, effective_to) do update
set
  units_per_inner_pack = excluded.units_per_inner_pack,
  packets_per_case = excluded.packets_per_case,
  nominal_case_weight_kg = excluded.nominal_case_weight_kg,
  variable_case_allowed = excluded.variable_case_allowed,
  effective_to = excluded.effective_to,
  updated_at = now(),
  updated_by = auth.uid();

commit;
