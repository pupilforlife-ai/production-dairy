begin;

create type public.product_type as enum ('raw', 'intermediate', 'finished');
create type public.weight_mode as enum ('fixed', 'variable');

create table public.units_of_measure (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  dimension text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.temperature_profiles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  target_c numeric,
  min_c numeric,
  max_c numeric,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  check (min_c is null or max_c is null or min_c <= max_c)
);

create table public.storage_locations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  location_type text not null,
  temperature_profile_id uuid references public.temperature_profiles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.product_families (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.product_families(id),
  code text not null unique,
  name text not null,
  product_type public.product_type not null,
  variant text,
  weight_mode public.weight_mode not null default 'fixed',
  storage_profile_id uuid references public.temperature_profiles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.skus (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  code text not null unique,
  description text not null,
  unit_weight_g numeric check (unit_weight_g is null or unit_weight_g > 0),
  pieces_per_packet integer check (pieces_per_packet is null or pieces_per_packet > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.packaging_configs (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references public.skus(id),
  units_per_inner_pack integer check (units_per_inner_pack is null or units_per_inner_pack > 0),
  packets_per_case integer check (packets_per_case is null or packets_per_case > 0),
  nominal_case_weight_kg numeric check (
    nominal_case_weight_kg is null or nominal_case_weight_kg > 0
  ),
  variable_case_allowed boolean not null default false,
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id),
  check (effective_to is null or effective_to >= effective_from),
  unique nulls not distinct (sku_id, effective_from, effective_to)
);

create table public.waste_reasons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  supplier_type text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create index storage_locations_temperature_profile_idx
on public.storage_locations (temperature_profile_id);
create index products_family_idx on public.products (family_id);
create index products_storage_profile_idx on public.products (storage_profile_id);
create index products_type_idx on public.products (product_type);
create index skus_product_idx on public.skus (product_id);
create index packaging_configs_sku_idx on public.packaging_configs (sku_id);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'units_of_measure', 'temperature_profiles', 'storage_locations', 'product_families',
    'products', 'skus', 'packaging_configs', 'waste_reasons', 'suppliers'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.current_user_role() is not null)',
      table_name || '_authenticated_select', table_name
    );
    execute format(
      'create policy %I on public.%I for insert to authenticated with check (public.is_owner())',
      table_name || '_owner_insert', table_name
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using (public.is_owner()) with check (public.is_owner())',
      table_name || '_owner_update', table_name
    );
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_profile_update_metadata()',
      table_name || '_set_update_metadata', table_name
    );
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row_change()',
      table_name || '_audit', table_name
    );
    execute format('grant select, insert, update on public.%I to authenticated', table_name);
    execute format('revoke delete on public.%I from anon, authenticated', table_name);
  end loop;
end;
$$;

insert into public.units_of_measure (code, name, dimension) values
  ('L', 'litre', 'volume'),
  ('mL', 'millilitre', 'volume'),
  ('kg', 'kilogram', 'mass'),
  ('g', 'gram', 'mass'),
  ('piece', 'piece', 'count'),
  ('packet', 'packet', 'count'),
  ('case', 'case', 'count'),
  ('bucket', 'bucket', 'count');

insert into public.temperature_profiles (name, target_c, min_c, max_c) values
  ('Chiller 3–5°C', 4, 3, 5),
  ('Freezer −18°C target', -18, null, null);

insert into public.storage_locations (code, name, location_type, temperature_profile_id) values
  ('SILO', 'Silo', 'milk_storage', null),
  ('BMC1', 'BMC 1', 'milk_storage', null),
  ('BMC2', 'BMC 2', 'milk_storage', null),
  ('HOLDING_TANK', 'Holding Tank', 'milk_storage', null),
  ('IBC_STORAGE', 'IBC Storage', 'milk_storage', null),
  ('BULK_INGREDIENT', 'Bulk Ingredient Store', 'ingredient_store', null),
  ('INTERMEDIATE_INGREDIENT', 'Intermediate Ingredient Store', 'ingredient_store', null),
  ('PRODUCTION', 'Production', 'production', null),
  ('CHILLER', 'Chiller', 'cold_storage', (select id from public.temperature_profiles where name = 'Chiller 3–5°C')),
  ('INTERMEDIATE_FREEZER', 'Intermediate Freezer', 'cold_storage', (select id from public.temperature_profiles where name = 'Freezer −18°C target')),
  ('FINISHED_PRODUCTION', 'Finished Production Stock', 'finished_stock', (select id from public.temperature_profiles where name = 'Freezer −18°C target')),
  ('DISTRIBUTION_HANDOVER', 'Distribution Handover', 'handover', null);

insert into public.product_families (code, name) values
  ('PANEER', 'Paneer'),
  ('HALLOUMI', 'Halloumi'),
  ('BUTTER', 'Butter'),
  ('GHEE', 'Ghee'),
  ('POPPERS', 'Poppers'),
  ('CREAM_INTERMEDIATES', 'Cream / Intermediates');

insert into public.products (family_id, code, name, product_type, variant, weight_mode) values
  ((select id from public.product_families where code = 'PANEER'), 'MALAI_PANEER', 'Malai / Full Fat Paneer', 'intermediate', 'D', 'variable'),
  ((select id from public.product_families where code = 'PANEER'), 'ROZANA_PANEER', 'Rozana / Medium Fat Paneer', 'intermediate', 'C/S', 'variable'),
  ((select id from public.product_families where code = 'POPPERS'), 'SPICY_PANEER_POPPERS', 'Spicy Paneer Poppers', 'finished', 'SPP', 'fixed'),
  ((select id from public.product_families where code = 'POPPERS'), 'HALLOUMI_POPPERS', 'Halloumi Poppers', 'finished', null, 'fixed'),
  ((select id from public.product_families where code = 'POPPERS'), 'JALAPENO_POPPERS', 'Jalapeño Poppers', 'finished', 'JP', 'fixed'),
  ((select id from public.product_families where code = 'BUTTER'), 'PURE_BUTTER_INTERMEDIATE', 'Pure Butter Intermediate', 'intermediate', null, 'variable'),
  ((select id from public.product_families where code = 'BUTTER'), 'PURE_BUTTER_BALLS', 'Pure Butter Balls', 'finished', 'PUBB', 'fixed'),
  ((select id from public.product_families where code = 'BUTTER'), 'BLENDED_BUTTER_BALLS', 'Blended Butter Balls', 'finished', 'PUBBB', 'fixed'),
  ((select id from public.product_families where code = 'BUTTER'), 'BLENDED_SALTED_BUTTER', 'Blended Salted Butter', 'finished', null, 'fixed'),
  ((select id from public.product_families where code = 'GHEE'), 'GHEE', 'Ghee', 'finished', null, 'fixed');

insert into public.skus (product_id, code, description, unit_weight_g, pieces_per_packet) values
  ((select id from public.products where code = 'MALAI_PANEER'), 'MPAN100', 'Malai Paneer 1 kg', 1000, null),
  ((select id from public.products where code = 'MALAI_PANEER'), 'MPAN400', 'Malai Paneer 400 g', 400, null),
  ((select id from public.products where code = 'MALAI_PANEER'), 'MPAN200', 'Malai Paneer 200 g', 200, null),
  ((select id from public.products where code = 'MALAI_PANEER'), 'VJPAN', 'Vejoy Paneer 200 g', 200, null),
  ((select id from public.products where code = 'MALAI_PANEER'), 'MPAN010', 'Fresh Malai Paneer Block', 400, null),
  ((select id from public.products where code = 'ROZANA_PANEER'), 'RPAN100', 'Rozana Paneer 1 kg', 1000, null),
  ((select id from public.products where code = 'ROZANA_PANEER'), 'RPAN400', 'Rozana Paneer 400 g', 400, null),
  ((select id from public.products where code = 'ROZANA_PANEER'), 'RPAN200', 'Rozana Paneer 200 g', 200, null),
  ((select id from public.products where code = 'ROZANA_PANEER'), 'RPAN010', 'Fresh Rozana Paneer Block', 400, null),
  ((select id from public.products where code = 'SPICY_PANEER_POPPERS'), 'SPP', 'Spicy Paneer Poppers', null, 8),
  ((select id from public.products where code = 'JALAPENO_POPPERS'), 'JP', 'Jalapeño Poppers', null, 6),
  ((select id from public.products where code = 'PURE_BUTTER_BALLS'), 'PUBB', 'Pure Butter Balls', 500, 12),
  ((select id from public.products where code = 'BLENDED_BUTTER_BALLS'), 'PUBBB', 'Blended Butter Balls', 500, 12),
  ((select id from public.products where code = 'BLENDED_SALTED_BUTTER'), 'PSBBB', 'Blended Salted Butter Balls', 500, 12),
  ((select id from public.products where code = 'BLENDED_SALTED_BUTTER'), 'BB05', 'Blended Salted Butter Bricks', 500, 1);

insert into public.packaging_configs (sku_id, units_per_inner_pack, packets_per_case, nominal_case_weight_kg, variable_case_allowed) values
  ((select id from public.skus where code = 'MPAN100'), 1, 15, 15, false),
  ((select id from public.skus where code = 'MPAN400'), 1, 24, 9.6, false),
  ((select id from public.skus where code = 'MPAN200'), 1, 24, 4.8, false),
  ((select id from public.skus where code = 'VJPAN'), 1, 20, 4, false),
  ((select id from public.skus where code = 'MPAN010'), 1, null, null, true),
  ((select id from public.skus where code = 'RPAN100'), 1, 15, 15, false),
  ((select id from public.skus where code = 'RPAN400'), 1, 24, 9.6, false),
  ((select id from public.skus where code = 'RPAN200'), 1, 24, 4.8, false),
  ((select id from public.skus where code = 'RPAN010'), 1, null, null, true),
  ((select id from public.skus where code = 'SPP'), 8, 12, null, false),
  ((select id from public.skus where code = 'JP'), 6, 12, null, false),
  ((select id from public.skus where code = 'PUBB'), 12, 3, 18, false),
  ((select id from public.skus where code = 'PUBBB'), 12, 3, 18, false),
  ((select id from public.skus where code = 'PSBBB'), 12, 3, 18, false),
  ((select id from public.skus where code = 'BB05'), 1, 30, 15, false);

insert into public.waste_reasons (code, name) values
  ('MILK_SPILLAGE', 'Milk spillage'),
  ('REJECTED_MILK', 'Rejected milk'),
  ('DAMAGED_PACKAGING', 'Damaged packaging'),
  ('GIVEAWAY', 'Product giveaway'),
  ('PROCESS_LOSS', 'Process loss'),
  ('REJECTED_POPPER', 'Rejected popper'),
  ('CONTAMINATION', 'Contamination or dropped product'),
  ('OTHER', 'Other');

commit;
