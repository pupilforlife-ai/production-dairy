begin;

create type public.ingredient_addition_stage as enum ('processing_vat', 'coagulation');

alter table public.ingredients
add column addition_stage public.ingredient_addition_stage;

-- Classify the five established paneer ingredients even if their codes or names
-- were entered with spaces, punctuation, abbreviations, or mixed case.
update public.ingredients
set addition_stage = 'processing_vat'::public.ingredient_addition_stage
where regexp_replace(lower(code), '[^a-z0-9]+', '', 'g') in ('supayield', 'creampowder')
   or regexp_replace(lower(name), '[^a-z0-9]+', '', 'g') in ('supayield', 'creampowder');

update public.ingredients
set addition_stage = 'coagulation'::public.ingredient_addition_stage
where regexp_replace(lower(code), '[^a-z0-9]+', '', 'g') in (
    'gdl', 'k', 'potassiumsorbate', 'cacl2', 'calciumchloride'
  )
   or regexp_replace(lower(name), '[^a-z0-9]+', '', 'g') in (
    'gdl', 'k', 'potassiumsorbate', 'cacl2', 'calciumchloride'
  );

create table public.production_round_ingredient_issues (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  recipe_version_id uuid not null references public.recipe_versions(id),
  recipe_component_id uuid not null references public.recipe_components(id),
  addition_stage public.ingredient_addition_stage not null,
  required_quantity numeric not null check (required_quantity > 0),
  issued_quantity numeric not null default 0 check (issued_quantity >= 0),
  shortage_quantity numeric generated always as (
    greatest(required_quantity - issued_quantity, 0)
  ) stored,
  uom_id uuid not null references public.units_of_measure(id),
  first_attempted_at timestamptz not null default now(),
  last_attempted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  unique (production_batch_id, recipe_component_id)
);

create index production_round_ingredient_issues_batch_idx
on public.production_round_ingredient_issues (production_batch_id, addition_stage);

create index production_round_ingredient_shortages_idx
on public.production_round_ingredient_issues (production_batch_id)
where shortage_quantity > 0;

alter table public.production_round_ingredient_issues enable row level security;

create policy production_round_ingredient_issues_select
on public.production_round_ingredient_issues for select to authenticated
using (public.current_user_role() is not null);

grant select on public.production_round_ingredient_issues to authenticated;
revoke insert, update, delete on public.production_round_ingredient_issues
from anon, authenticated;

create trigger production_round_ingredient_issues_set_update_metadata
before update on public.production_round_ingredient_issues
for each row execute function public.set_profile_update_metadata();

create trigger production_round_ingredient_issues_audit
after insert or update or delete on public.production_round_ingredient_issues
for each row execute function public.audit_row_change();

create or replace function public.effective_recipe_version_for_product(
  requested_product_id uuid,
  requested_at timestamptz
)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select version.id
  from public.recipe_versions version
  join public.recipes recipe on recipe.id = version.recipe_id
  where recipe.product_id = requested_product_id
    and recipe.active
    and version.effective_from <= (requested_at at time zone 'Africa/Johannesburg')::date
    and (
      version.effective_to is null
      or version.effective_to >= (requested_at at time zone 'Africa/Johannesburg')::date
    )
  order by version.effective_from desc, version.version_number desc, recipe.created_at desc
  limit 1;
$$;

revoke all on function public.effective_recipe_version_for_product(uuid, timestamptz)
from public;

create or replace function public.assign_production_round_recipe()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  recipe_date timestamptz;
begin
  select started_at into recipe_date
  from public.production_shifts
  where id = new.shift_id;

  new.recipe_version_id := public.effective_recipe_version_for_product(
    new.product_id,
    coalesce(recipe_date, new.started_at, now())
  );
  return new;
end;
$$;

create trigger production_batches_assign_recipe
before insert or update of product_id on public.production_batches
for each row execute function public.assign_production_round_recipe();

-- Connect existing rounds to their effective recipe without retroactively
-- consuming stock. Their next relevant board update will reconcile ingredients.
update public.production_batches batch
set recipe_version_id = public.effective_recipe_version_for_product(
  batch.product_id,
  coalesce(shift.started_at, batch.started_at, batch.created_at)
)
from public.production_shifts shift
where shift.id = batch.shift_id
  and batch.recipe_version_id is null;

create or replace function public.issue_due_production_ingredients(
  requested_batch_id uuid
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  target_version public.recipe_versions%rowtype;
  due_stages public.ingredient_addition_stage[];
  component record;
  issue_row public.production_round_ingredient_issues%rowtype;
  stock record;
  available_quantity numeric;
  quantity_to_issue numeric;
  quantity_remaining numeric;
begin
  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;
  if not found or target_batch.status = 'cancelled'::public.production_status then return; end if;

  due_stages := case target_batch.process_stage
    when 'vat_1'::public.paneer_process_stage
      then array[]::public.ingredient_addition_stage[]
    when 'vat_2'::public.paneer_process_stage
      then array['processing_vat'::public.ingredient_addition_stage]
    when 'vat_3'::public.paneer_process_stage
      then array['processing_vat'::public.ingredient_addition_stage]
    else array[
      'processing_vat'::public.ingredient_addition_stage,
      'coagulation'::public.ingredient_addition_stage
    ]
  end;
  if coalesce(array_length(due_stages, 1), 0) = 0 then return; end if;

  if target_batch.recipe_version_id is null then
    return;
  end if;

  select * into target_version
  from public.recipe_versions
  where id = target_batch.recipe_version_id;
  if not found then return; end if;

  for component in
    select
      recipe_component.id as component_id,
      recipe_component.uom_id,
      ingredient.addition_stage,
      inventory_item.id as inventory_item_id,
      recipe_component.quantity
        * coalesce(
            target_batch.actual_primary_input_quantity,
            target_batch.planned_input_quantity,
            500
          )
        / target_version.basis_quantity as required_quantity
    from public.recipe_components recipe_component
    join public.ingredients ingredient on ingredient.id = recipe_component.ingredient_id
    left join public.inventory_items inventory_item
      on inventory_item.ingredient_id = ingredient.id
      and inventory_item.active
    where recipe_component.recipe_version_id = target_version.id
      and ingredient.addition_stage = any(due_stages)
    order by recipe_component.sequence nulls last, recipe_component.id
  loop
    insert into public.production_round_ingredient_issues (
      production_batch_id, recipe_version_id, recipe_component_id,
      addition_stage, required_quantity, issued_quantity, uom_id,
      created_by, updated_by
    ) values (
      target_batch.id, target_version.id, component.component_id,
      component.addition_stage, component.required_quantity, 0,
      component.uom_id, auth.uid(), auth.uid()
    )
    on conflict (production_batch_id, recipe_component_id) do update
    set
      required_quantity = excluded.required_quantity,
      last_attempted_at = now(),
      updated_by = auth.uid()
    returning * into issue_row;

    quantity_remaining := greatest(
      component.required_quantity - issue_row.issued_quantity,
      0
    );

    for stock in
      select
        balance.inventory_lot_id,
        balance.storage_location_id
      from public.inventory_balances balance
      join public.inventory_lots lot on lot.id = balance.inventory_lot_id
      where balance.inventory_item_id = component.inventory_item_id
        and balance.uom_id = component.uom_id
        and balance.current_quantity > 0
        and lot.status = 'active'::public.inventory_lot_status
      order by lot.expiry_date asc nulls last, lot.received_at, lot.id,
        balance.storage_location_id
    loop
      exit when quantity_remaining <= 0;

      perform 1
      from public.inventory_lots
      where id = stock.inventory_lot_id
      for update;

      available_quantity := public.current_inventory_balance(
        stock.inventory_lot_id,
        stock.storage_location_id
      );
      quantity_to_issue := least(quantity_remaining, greatest(available_quantity, 0));
      if quantity_to_issue <= 0 then continue; end if;

      insert into public.inventory_movements (
        inventory_item_id, inventory_lot_id, source_location_id,
        movement_type, quantity, uom_id, production_batch_id,
        notes, occurred_at, created_by
      ) values (
        component.inventory_item_id, stock.inventory_lot_id,
        stock.storage_location_id, 'consume', quantity_to_issue,
        component.uom_id, target_batch.id,
        'Automatic recipe issue at ' || replace(component.addition_stage::text, '_', ' '),
        now(), auth.uid()
      );

      update public.production_round_ingredient_issues
      set
        issued_quantity = issued_quantity + quantity_to_issue,
        last_attempted_at = now(),
        updated_by = auth.uid()
      where id = issue_row.id
      returning * into issue_row;

      quantity_remaining := greatest(quantity_remaining - quantity_to_issue, 0);
    end loop;

    update public.production_round_ingredient_issues
    set last_attempted_at = now(), updated_by = auth.uid()
    where id = issue_row.id;
  end loop;
end;
$$;

revoke all on function public.issue_due_production_ingredients(uuid) from public;

create or replace function public.process_production_round_ingredients()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.issue_due_production_ingredients(new.id);
  return new;
end;
$$;

create trigger production_batches_issue_ingredients_after_insert
after insert on public.production_batches
for each row execute function public.process_production_round_ingredients();

create trigger production_batches_issue_ingredients_after_update
after update of product_id, process_stage, actual_primary_input_quantity
on public.production_batches
for each row execute function public.process_production_round_ingredients();

create or replace function public.protect_round_type_after_ingredient_issue()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.product_id is distinct from old.product_id and exists (
    select 1
    from public.production_round_ingredient_issues
    where production_batch_id = old.id
  ) then
    raise exception 'Paneer type cannot change after recipe ingredients have been processed';
  end if;
  return new;
end;
$$;

create trigger production_batches_protect_ingredient_issue_type
before update of product_id on public.production_batches
for each row execute function public.protect_round_type_after_ingredient_issue();

create or replace function public.retry_production_round_ingredient_shortages(
  requested_batch_id uuid
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;
  perform public.issue_due_production_ingredients(requested_batch_id);
end;
$$;

revoke all on function public.retry_production_round_ingredient_shortages(uuid)
from public, anon;
grant execute on function public.retry_production_round_ingredient_shortages(uuid)
to authenticated;

create or replace function public.create_staged_recipe_ingredient(
  requested_code text,
  requested_name text,
  requested_uom_id uuid,
  requested_addition_stage public.ingredient_addition_stage
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_ingredient_id uuid;
begin
  if not public.is_owner() then raise exception 'Only an owner can create ingredients'; end if;
  if length(trim(coalesce(requested_code, ''))) = 0
    or length(trim(coalesce(requested_name, ''))) = 0 then
    raise exception 'Ingredient code and name are required';
  end if;
  if requested_addition_stage is null then
    raise exception 'Ingredient addition stage is required';
  end if;
  if not exists (
    select 1 from public.units_of_measure where id = requested_uom_id and active
  ) then raise exception 'Unit of measure is unavailable'; end if;

  insert into public.ingredients (
    code, name, default_uom_id, addition_stage, created_by, updated_by
  ) values (
    upper(trim(requested_code)), trim(requested_name), requested_uom_id,
    requested_addition_stage, auth.uid(), auth.uid()
  ) returning id into new_ingredient_id;

  insert into public.inventory_items (
    item_type, ingredient_id, code, name, default_uom_id, created_by, updated_by
  ) values (
    'ingredient', new_ingredient_id, upper(trim(requested_code)),
    trim(requested_name), requested_uom_id, auth.uid(), auth.uid()
  );

  return new_ingredient_id;
end;
$$;

revoke all on function public.create_staged_recipe_ingredient(
  text, text, uuid, public.ingredient_addition_stage
) from public, anon;
grant execute on function public.create_staged_recipe_ingredient(
  text, text, uuid, public.ingredient_addition_stage
) to authenticated;

commit;
