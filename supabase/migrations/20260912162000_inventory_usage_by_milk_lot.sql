begin;

create or replace view public.inventory_usage_by_milk_lot
with (security_invoker = true)
as
select
  item.id as inventory_item_id,
  item.code as item_code,
  item.name as item_name,
  source_lot.id as source_lot_id,
  source_lot.lot_code as source_lot_code,
  count(distinct batch.id)::integer as round_count,
  count(
    distinct batch.id
  ) filter (
    where upper(coalesce(product.variant, product.code, product.name)) = 'D'
      or upper(product.code) like '%_D'
      or upper(product.name) like '% D %'
  )::integer as d_rounds,
  count(
    distinct batch.id
  ) filter (
    where upper(coalesce(product.variant, product.code, product.name)) in ('C/S', 'CS')
      or upper(product.code) like '%CS%'
      or upper(product.name) like '%C/S%'
  )::integer as cs_rounds,
  sum(movement.quantity) as total_quantity,
  uom.code as uom_code,
  max(movement.occurred_at) as last_used_at
from public.inventory_movements movement
join public.inventory_items item on item.id = movement.inventory_item_id
join public.units_of_measure uom on uom.id = movement.uom_id
join public.production_batches batch on batch.id = movement.production_batch_id
join public.source_lots source_lot on source_lot.id = batch.parent_source_lot_id
left join public.products product on product.id = batch.product_id
where movement.movement_type = 'consume'::public.inventory_movement_type
  and source_lot.lot_type = 'milk'::public.source_lot_type
group by
  item.id,
  item.code,
  item.name,
  source_lot.id,
  source_lot.lot_code,
  uom.code;

revoke all on public.inventory_usage_by_milk_lot from anon;
grant select on public.inventory_usage_by_milk_lot to authenticated;

notify pgrst, 'reload schema';

commit;
