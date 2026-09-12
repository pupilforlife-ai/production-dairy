begin;

create or replace function public.list_impersonatable_workers()
returns table (
  id uuid,
  email text,
  display_name text,
  role public.app_role,
  active boolean,
  approval_status public.user_approval_status
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.current_user_role() not in ('owner'::public.app_role, 'admin'::public.app_role) then
    raise exception 'Owner or admin access required';
  end if;

  return query
  select
    profile.id,
    account.email::text,
    profile.display_name,
    profile.role,
    profile.active,
    profile.approval_status
  from public.profiles profile
  join auth.users account on account.id = profile.id
  where profile.role = 'factory_worker'::public.app_role
    and profile.active = true
    and profile.approval_status = 'approved'::public.user_approval_status
  order by profile.display_name nulls last, account.email;
end;
$$;

revoke all on function public.list_impersonatable_workers() from public;
grant execute on function public.list_impersonatable_workers() to authenticated;

commit;
