begin;

create or replace function public.create_recipe_with_version(
  requested_product_id uuid,
  requested_name text,
  requested_basis_quantity numeric,
  requested_basis_uom_id uuid,
  requested_effective_from date,
  requested_components jsonb
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  generated_recipe_id uuid := gen_random_uuid();
  generated_version_id uuid := gen_random_uuid();
  component jsonb;
  component_type text;
  component_material_id uuid;
  component_quantity numeric;
  component_uom_id uuid;
  component_tolerance_min numeric;
  component_tolerance_max numeric;
  component_key text;
  seen_component_keys text[] := array[]::text[];
  component_sequence integer := 0;
begin
  if not public.is_owner() then raise exception 'Owner access required'; end if;
  if not exists (
    select 1 from public.products where id = requested_product_id and active
  ) then raise exception 'Select an active recipe product'; end if;
  if length(trim(coalesce(requested_name, ''))) = 0 then
    raise exception 'Recipe name is required';
  end if;
  if requested_basis_quantity is null or requested_basis_quantity <= 0 then
    raise exception 'Recipe basis quantity must be positive';
  end if;
  if not exists (
    select 1 from public.units_of_measure where id = requested_basis_uom_id and active
  ) then raise exception 'Select an active recipe basis unit'; end if;
  if requested_effective_from is null then raise exception 'Effective date is required'; end if;
  if jsonb_typeof(requested_components) <> 'array'
    or jsonb_array_length(requested_components) = 0 then
    raise exception 'Add at least one recipe component';
  end if;

  insert into public.recipes (
    id, product_id, name, confidential, active, created_by, updated_by
  ) values (
    generated_recipe_id, requested_product_id, trim(requested_name),
    true, true, auth.uid(), auth.uid()
  );

  insert into public.recipe_versions (
    id, recipe_id, version_number, basis_quantity, basis_uom_id,
    effective_from, created_by
  ) values (
    generated_version_id, generated_recipe_id, 1, requested_basis_quantity,
    requested_basis_uom_id, requested_effective_from, auth.uid()
  );

  for component in select value from jsonb_array_elements(requested_components)
  loop
    component_sequence := component_sequence + 1;
    component_type := component ->> 'type';
    component_material_id := (component ->> 'material_id')::uuid;
    component_quantity := (component ->> 'quantity')::numeric;
    component_uom_id := (component ->> 'uom_id')::uuid;
    component_tolerance_min := nullif(component ->> 'tolerance_min', '')::numeric;
    component_tolerance_max := nullif(component ->> 'tolerance_max', '')::numeric;

    if component_type not in ('ingredient', 'product') then
      raise exception 'Invalid recipe component type';
    end if;
    if component_quantity is null or component_quantity <= 0 then
      raise exception 'Every component quantity must be positive';
    end if;
    if not exists (
      select 1 from public.units_of_measure where id = component_uom_id and active
    ) then raise exception 'A component uses an unavailable unit'; end if;
    if component_tolerance_min is not null and component_tolerance_min < 0 then
      raise exception 'Minimum tolerance cannot be negative';
    end if;
    if component_tolerance_max is not null and component_tolerance_max < 0 then
      raise exception 'Maximum tolerance cannot be negative';
    end if;
    if component_tolerance_min is not null and component_tolerance_max is not null
      and component_tolerance_min > component_tolerance_max then
      raise exception 'Minimum tolerance cannot exceed maximum tolerance';
    end if;

    component_key := component_type || ':' || component_material_id::text;
    if component_key = any(seen_component_keys) then
      raise exception 'The same component cannot be added twice';
    end if;
    seen_component_keys := array_append(seen_component_keys, component_key);

    if component_type = 'ingredient' then
      if not exists (
        select 1 from public.ingredients where id = component_material_id and active
      ) then raise exception 'Select an active ingredient'; end if;
      insert into public.recipe_components (
        recipe_version_id, ingredient_id, quantity, uom_id,
        tolerance_min, tolerance_max, sequence, created_by
      ) values (
        generated_version_id, component_material_id, component_quantity,
        component_uom_id, component_tolerance_min, component_tolerance_max,
        component_sequence, auth.uid()
      );
    else
      if component_material_id = requested_product_id then
        raise exception 'A product cannot be a component of its own recipe';
      end if;
      if not exists (
        select 1 from public.products where id = component_material_id and active
      ) then raise exception 'Select an active product component'; end if;
      insert into public.recipe_components (
        recipe_version_id, material_product_id, quantity, uom_id,
        tolerance_min, tolerance_max, sequence, created_by
      ) values (
        generated_version_id, component_material_id, component_quantity,
        component_uom_id, component_tolerance_min, component_tolerance_max,
        component_sequence, auth.uid()
      );
    end if;
  end loop;

  return generated_recipe_id;
end;
$$;

revoke all on function public.create_recipe_with_version(
  uuid, text, numeric, uuid, date, jsonb
) from public;
grant execute on function public.create_recipe_with_version(
  uuid, text, numeric, uuid, date, jsonb
) to authenticated;

commit;
