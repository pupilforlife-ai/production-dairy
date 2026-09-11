begin;

do $$
begin
  if exists (
    select 1
    from pg_enum enum_value
    join pg_type enum_type on enum_type.oid = enum_value.enumtypid
    join pg_namespace enum_schema on enum_schema.oid = enum_type.typnamespace
    where enum_schema.nspname = 'public'
      and enum_type.typname = 'app_role'
      and enum_value.enumlabel = 'production_manager'
  ) then
    alter type public.app_role rename value 'production_manager' to 'factory_worker';
  end if;
end;
$$;

alter type public.app_role add value if not exists 'admin';

create type public.user_approval_status as enum (
  'pending',
  'approved',
  'disapproved'
);

alter table public.profiles
add column approval_status public.user_approval_status;

update public.profiles
set approval_status = case
  when active then 'approved'::public.user_approval_status
  else 'pending'::public.user_approval_status
end;

alter table public.profiles
alter column approval_status set default 'pending'::public.user_approval_status,
alter column approval_status set not null;

alter table public.profiles
add constraint profiles_approval_matches_active_check check (
  active = (approval_status = 'approved'::public.user_approval_status)
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (
    id, display_name, role, active, approval_status
  ) values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'display_name',
      split_part(coalesce(new.email, ''), '@', 1)
    ),
    case
      when lower(new.email) = 'production-dairy@vejoy.co.za'
        then 'owner'::public.app_role
      else 'factory_worker'::public.app_role
    end,
    lower(new.email) = 'production-dairy@vejoy.co.za',
    case
      when lower(new.email) = 'production-dairy@vejoy.co.za'
        then 'approved'::public.user_approval_status
      else 'pending'::public.user_approval_status
    end
  );
  return new;
end;
$$;

create or replace function public.list_app_users()
returns table (
  id uuid,
  email text,
  display_name text,
  role public.app_role,
  approval_status public.user_approval_status,
  active boolean,
  registered_at timestamptz,
  last_sign_in_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'Owner access required'; end if;

  return query
  select
    profile.id,
    account.email::text,
    profile.display_name,
    profile.role,
    profile.approval_status,
    profile.active,
    account.created_at,
    account.last_sign_in_at
  from public.profiles profile
  join auth.users account on account.id = profile.id
  order by
    case profile.approval_status
      when 'pending'::public.user_approval_status then 0
      when 'approved'::public.user_approval_status then 1
      else 2
    end,
    account.created_at desc;
end;
$$;

create or replace function public.manage_app_user(
  requested_user_id uuid,
  requested_status text,
  requested_role text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target_profile public.profiles%rowtype;
  approved_owner_count integer;
begin
  if not public.is_owner() then raise exception 'Owner access required'; end if;
  if requested_status not in ('pending', 'approved', 'disapproved') then
    raise exception 'Invalid user status';
  end if;
  if requested_role not in ('owner', 'admin', 'factory_worker') then
    raise exception 'Invalid user role';
  end if;

  select * into target_profile
  from public.profiles
  where id = requested_user_id
  for update;

  if not found then raise exception 'User profile does not exist'; end if;

  if requested_user_id = auth.uid()
    and (requested_status <> 'approved' or requested_role <> 'owner') then
    raise exception 'You cannot remove your own owner access';
  end if;

  if target_profile.role = 'owner'::public.app_role
    and target_profile.active
    and (requested_status <> 'approved' or requested_role <> 'owner') then
    select count(*) into approved_owner_count
    from public.profiles
    where role = 'owner'::public.app_role
      and approval_status = 'approved'::public.user_approval_status;
    if approved_owner_count <= 1 then
      raise exception 'The final approved owner cannot be demoted or disapproved';
    end if;
  end if;

  update public.profiles
  set
    role = requested_role::public.app_role,
    approval_status = requested_status::public.user_approval_status,
    active = requested_status = 'approved'
  where id = requested_user_id;
end;
$$;

revoke all on function public.list_app_users() from public;
revoke all on function public.manage_app_user(uuid, text, text) from public;
grant execute on function public.list_app_users() to authenticated;
grant execute on function public.manage_app_user(uuid, text, text) to authenticated;

commit;
