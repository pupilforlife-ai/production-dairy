begin;

create table public.ingredients (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  default_uom_id uuid not null references public.units_of_measure(id),
  confidential_name_alias text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.recipes (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  name text not null,
  confidential boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  unique (product_id, name)
);

create table public.recipe_versions (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.recipes(id),
  version_number integer not null check (version_number > 0),
  basis_quantity numeric not null check (basis_quantity > 0),
  basis_uom_id uuid not null references public.units_of_measure(id),
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  check (effective_to is null or effective_to >= effective_from),
  unique (recipe_id, version_number)
);

create table public.recipe_components (
  id uuid primary key default gen_random_uuid(),
  recipe_version_id uuid not null references public.recipe_versions(id),
  material_product_id uuid references public.products(id),
  ingredient_id uuid references public.ingredients(id),
  quantity numeric not null check (quantity > 0),
  uom_id uuid not null references public.units_of_measure(id),
  tolerance_min numeric,
  tolerance_max numeric,
  sequence integer,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  check (num_nonnulls(material_product_id, ingredient_id) = 1),
  check (tolerance_min is null or tolerance_min >= 0),
  check (tolerance_max is null or tolerance_max >= 0),
  check (tolerance_min is null or tolerance_max is null or tolerance_min <= tolerance_max)
);

create index ingredients_default_uom_idx on public.ingredients (default_uom_id);
create index recipes_product_idx on public.recipes (product_id);
create index recipe_versions_recipe_idx on public.recipe_versions (recipe_id, version_number desc);
create index recipe_components_version_idx on public.recipe_components (recipe_version_id, sequence);
create index recipe_components_product_idx on public.recipe_components (material_product_id);
create index recipe_components_ingredient_idx on public.recipe_components (ingredient_id);

create or replace function public.can_read_recipe(requested_recipe_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.recipes
    where id = requested_recipe_id
      and (
        public.is_owner()
        or (active = true and confidential = false and public.current_user_role() is not null)
      )
  );
$$;

revoke all on function public.can_read_recipe(uuid) from public;
grant execute on function public.can_read_recipe(uuid) to authenticated;

alter table public.ingredients enable row level security;
alter table public.recipes enable row level security;
alter table public.recipe_versions enable row level security;
alter table public.recipe_components enable row level security;

create policy ingredients_authenticated_select on public.ingredients for select to authenticated
using (public.current_user_role() is not null);
create policy ingredients_owner_insert on public.ingredients for insert to authenticated
with check (public.is_owner());
create policy ingredients_owner_update on public.ingredients for update to authenticated
using (public.is_owner()) with check (public.is_owner());

create policy recipes_authorized_select on public.recipes for select to authenticated
using (public.can_read_recipe(id));
create policy recipes_owner_insert on public.recipes for insert to authenticated
with check (public.is_owner());
create policy recipes_owner_update on public.recipes for update to authenticated
using (public.is_owner()) with check (public.is_owner());

create policy recipe_versions_authorized_select on public.recipe_versions for select to authenticated
using (public.can_read_recipe(recipe_id));
create policy recipe_versions_owner_insert on public.recipe_versions for insert to authenticated
with check (public.is_owner());

create policy recipe_components_authorized_select on public.recipe_components for select to authenticated
using (
  exists (
    select 1 from public.recipe_versions
    where recipe_versions.id = recipe_components.recipe_version_id
      and public.can_read_recipe(recipe_versions.recipe_id)
  )
);
create policy recipe_components_owner_insert on public.recipe_components for insert to authenticated
with check (public.is_owner());

grant select, insert, update on public.ingredients, public.recipes to authenticated;
grant select, insert on public.recipe_versions, public.recipe_components to authenticated;
revoke delete on public.ingredients, public.recipes, public.recipe_versions, public.recipe_components
from anon, authenticated;
revoke update on public.recipe_versions, public.recipe_components from anon, authenticated;

create trigger ingredients_set_update_metadata
before update on public.ingredients
for each row execute function public.set_profile_update_metadata();
create trigger recipes_set_update_metadata
before update on public.recipes
for each row execute function public.set_profile_update_metadata();

create trigger ingredients_audit
after insert or update or delete on public.ingredients
for each row execute function public.audit_row_change();
create trigger recipes_audit
after insert or update or delete on public.recipes
for each row execute function public.audit_row_change();
create trigger recipe_versions_audit
after insert or update or delete on public.recipe_versions
for each row execute function public.audit_row_change();
create trigger recipe_components_audit
after insert or update or delete on public.recipe_components
for each row execute function public.audit_row_change();

insert into public.ingredients (code, name, default_uom_id) values
  ('AF_OIL', 'AF oil', (select id from public.units_of_measure where code = 'kg')),
  ('BUTTER_REPLACER', 'Butter replacer', (select id from public.units_of_measure where code = 'kg'));

insert into public.recipes (product_id, name, confidential) values
  ((select id from public.products where code = 'GHEE'), 'Standard ghee formula', true),
  ((select id from public.products where code = 'BLENDED_BUTTER_BALLS'), 'Standard blended butter formula', true);

insert into public.recipe_versions (
  recipe_id, version_number, basis_quantity, basis_uom_id, effective_from
) values
  ((select id from public.recipes where name = 'Standard ghee formula'), 1, 105, (select id from public.units_of_measure where code = 'kg'), current_date),
  ((select id from public.recipes where name = 'Standard blended butter formula'), 1, 21.5, (select id from public.units_of_measure where code = 'kg'), current_date);

insert into public.recipe_components (
  recipe_version_id, material_product_id, ingredient_id, quantity, uom_id, sequence
) values
  (
    (select id from public.recipe_versions where recipe_id = (select id from public.recipes where name = 'Standard ghee formula') and version_number = 1),
    (select id from public.products where code = 'PURE_BUTTER_INTERMEDIATE'),
    null,
    92.5,
    (select id from public.units_of_measure where code = 'kg'),
    1
  ),
  (
    (select id from public.recipe_versions where recipe_id = (select id from public.recipes where name = 'Standard ghee formula') and version_number = 1),
    null,
    (select id from public.ingredients where code = 'AF_OIL'),
    12.5,
    (select id from public.units_of_measure where code = 'kg'),
    2
  ),
  (
    (select id from public.recipe_versions where recipe_id = (select id from public.recipes where name = 'Standard blended butter formula') and version_number = 1),
    (select id from public.products where code = 'PURE_BUTTER_INTERMEDIATE'),
    null,
    16.5,
    (select id from public.units_of_measure where code = 'kg'),
    1
  ),
  (
    (select id from public.recipe_versions where recipe_id = (select id from public.recipes where name = 'Standard blended butter formula') and version_number = 1),
    null,
    (select id from public.ingredients where code = 'BUTTER_REPLACER'),
    5,
    (select id from public.units_of_measure where code = 'kg'),
    2
  );

commit;
