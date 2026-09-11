begin;

create table public.production_round_handling_events (
  id uuid primary key default gen_random_uuid(),
  production_batch_id uuid not null references public.production_batches(id),
  event_type text not null check (event_type = 'cling_wrapped'),
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now()
);

create index production_round_handling_events_batch_idx
on public.production_round_handling_events (production_batch_id, recorded_at desc);

create or replace function public.manage_cling_wrapped_round()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  recorded_count integer;
  missing_count integer;
begin
  if old.cut_format = 'cling_wrapped'::public.paneer_cut_format
    and new.cut_format = 'cling_wrapped'::public.paneer_cut_format then
    if new.process_stage is distinct from old.process_stage then
      raise exception 'A cling-wrapped round remains ready for cutting until its final cut is selected';
    end if;
    if new.product_id is distinct from old.product_id then
      raise exception 'Paneer type cannot change while the round is cling wrapped';
    end if;
    if new.cut_by is distinct from old.cut_by then
      raise exception 'Select the final cut before recording Cut by';
    end if;
  end if;

  if new.cut_format = 'cling_wrapped'::public.paneer_cut_format then
    if old.cut_format is distinct from new.cut_format then
      if new.process_stage <> 'ready_for_cutting'::public.paneer_process_stage then
        raise exception 'Cling wrapping is recorded after resting, when the round is ready for cutting';
      end if;
      if new.pressed_block_count is null then
        raise exception 'Record the number of pressed blocks before cling wrapping';
      end if;

      select count(*), count(*) filter (where weight_kg is null)
      into recorded_count, missing_count
      from public.production_round_blocks
      where production_batch_id = new.id;

      if recorded_count <> new.pressed_block_count or missing_count > 0 then
        raise exception 'Record the weight of every pressed block before cling wrapping';
      end if;
    end if;

    new.cut_by := null;
    new.cut_completed_at := null;
    new.status := 'ready_for_cutting'::public.production_status;
    new.cutting_allocation := 'Cling wrapped — stored in chiller';
  end if;
  return new;
end;
$$;

create trigger production_batches_manage_cling_wrapped
before update on public.production_batches
for each row execute function public.manage_cling_wrapped_round();

create or replace function public.record_cling_wrapped_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.cut_format = 'cling_wrapped'::public.paneer_cut_format
    and old.cut_format is distinct from new.cut_format then
    insert into public.production_round_handling_events (
      production_batch_id, event_type, recorded_by
    ) values (
      new.id, 'cling_wrapped', auth.uid()
    );
  end if;
  return new;
end;
$$;

create trigger production_batches_record_cling_wrapped
after update on public.production_batches
for each row execute function public.record_cling_wrapped_event();

alter table public.production_round_handling_events enable row level security;
create policy production_round_handling_events_select
on public.production_round_handling_events for select to authenticated
using (public.current_user_role() is not null);

grant select on public.production_round_handling_events to authenticated;
revoke insert, update, delete on public.production_round_handling_events from anon, authenticated;

create trigger production_round_handling_events_audit
after insert or update or delete on public.production_round_handling_events
for each row execute function public.audit_row_change();

commit;
