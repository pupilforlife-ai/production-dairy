begin;

alter table public.production_sku_packing_verifications
add column case_weight_kg_used numeric check (
  case_weight_kg_used is null or case_weight_kg_used > 0
);

update public.production_sku_packing_verifications verification
set case_weight_kg_used = coalesce(
  (
    select config.nominal_case_weight_kg
    from public.packaging_configs config
    where config.sku_id = verification.sku_id
      and config.effective_from <= verification.verified_at::date
      and (config.effective_to is null or config.effective_to >= verification.verified_at::date)
    order by config.effective_from desc
    limit 1
  ),
  verification.packets_per_case_used * sku.unit_weight_g / 1000
)
from public.skus sku
where verification.sku_id = sku.id
  and verification.packets_per_case_used is not null;

create function public.verify_production_sku_packing(
  requested_sku_id uuid,
  requested_corrected_cases integer,
  requested_corrected_loose_packets integer,
  requested_source_round_uncertain boolean,
  requested_correction_reason text,
  requested_packets_per_case integer,
  requested_case_weight_kg numeric
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  verification_id uuid;
  variable_case_allowed boolean := false;
  configured_case_weight_kg numeric;
  sku_unit_weight_g numeric;
  packet_case_count integer;
  case_weight_kg numeric;
begin
  if requested_case_weight_kg is not null and requested_case_weight_kg <= 0 then
    raise exception 'Case weight must be greater than zero';
  end if;

  select sku.unit_weight_g, config.variable_case_allowed,
    config.nominal_case_weight_kg
  into sku_unit_weight_g, variable_case_allowed, configured_case_weight_kg
  from public.skus sku
  left join lateral (
    select packaging.variable_case_allowed, packaging.nominal_case_weight_kg
    from public.packaging_configs packaging
    where packaging.sku_id = sku.id
      and packaging.effective_from <= current_date
      and (packaging.effective_to is null or packaging.effective_to >= current_date)
    order by packaging.effective_from desc
    limit 1
  ) config on true
  where sku.id = requested_sku_id
    and sku.active;

  if not found then raise exception 'Finished SKU is unavailable'; end if;
  if requested_case_weight_kg is not null
    and not coalesce(variable_case_allowed, false) then
    raise exception 'This SKU uses the fixed case weight from master data';
  end if;

  verification_id := public.verify_production_sku_packing(
    requested_sku_id,
    requested_corrected_cases,
    requested_corrected_loose_packets,
    requested_source_round_uncertain,
    requested_correction_reason,
    requested_packets_per_case
  );

  select verification.packets_per_case_used
  into packet_case_count
  from public.production_sku_packing_verifications verification
  where verification.id = verification_id;

  case_weight_kg := case
    when coalesce(variable_case_allowed, false) then coalesce(
      requested_case_weight_kg,
      packet_case_count * sku_unit_weight_g / 1000
    )
    else coalesce(
      configured_case_weight_kg,
      packet_case_count * sku_unit_weight_g / 1000
    )
  end;

  if requested_corrected_cases > 0 and case_weight_kg is null then
    raise exception 'Enter case weight before cases can be verified';
  end if;

  update public.production_sku_packing_verifications
  set case_weight_kg_used = case_weight_kg,
    updated_by = auth.uid()
  where id = verification_id;

  return verification_id;
end;
$$;

revoke execute on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text, integer
) from authenticated;
revoke all on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text, integer, numeric
) from public, anon;
grant execute on function public.verify_production_sku_packing(
  uuid, integer, integer, boolean, text, integer, numeric
) to authenticated;

commit;
