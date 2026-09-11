begin;

create or replace function public.set_production_batch_status(
  requested_batch_id uuid,
  requested_status public.production_status
)
returns public.production_status
language plpgsql security definer set search_path = ''
as $$
declare
  target_batch public.production_batches%rowtype;
  persisted_status public.production_status;
begin
  if public.current_user_role() is null then raise exception 'Not authorized'; end if;

  select * into target_batch
  from public.production_batches
  where id = requested_batch_id
  for update;

  if not found then raise exception 'Production round does not exist'; end if;
  if target_batch.locked_at is not null then
    raise exception 'A locked production round cannot be changed';
  end if;

  update public.production_batches
  set
    status = requested_status,
    completed_at = case
      when requested_status = 'handed_over'::public.production_status then now()
      else null
    end
  where id = requested_batch_id
  returning status into persisted_status;

  if persisted_status is distinct from requested_status then
    raise exception 'Production status was not saved';
  end if;

  return persisted_status;
end;
$$;

revoke all on function public.set_production_batch_status(
  uuid, public.production_status
) from public;
grant execute on function public.set_production_batch_status(
  uuid, public.production_status
) to authenticated;

commit;
