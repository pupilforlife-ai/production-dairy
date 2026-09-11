begin;

insert into public.profiles (id, display_name, role, active)
select
  id,
  coalesce(raw_user_meta_data ->> 'display_name', split_part(coalesce(email, ''), '@', 1)),
  'owner'::public.app_role,
  true
from auth.users
where lower(email) = 'production-dairy@vejoy.co.za'
on conflict (id) do update
set
  role = 'owner'::public.app_role,
  active = true,
  updated_at = now();

do $$
begin
  if not exists (
    select 1
    from public.profiles p
    join auth.users u on u.id = p.id
    where lower(u.email) = 'production-dairy@vejoy.co.za'
      and p.role = 'owner'::public.app_role
      and p.active = true
  ) then
    raise notice 'Bootstrap owner account is not registered yet; it will be activated automatically when created';
  end if;
end;
$$;

commit;
