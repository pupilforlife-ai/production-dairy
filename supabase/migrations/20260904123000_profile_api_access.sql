begin;

grant select on public.profiles to authenticated;
grant select on public.audit_events, public.corrections to authenticated;

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
    raise notice 'Bootstrap owner profile is not registered yet';
  end if;
end;
$$;

commit;
