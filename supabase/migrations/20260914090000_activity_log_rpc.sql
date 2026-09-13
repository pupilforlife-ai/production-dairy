begin;

create or replace function public.list_activity_events(requested_limit integer default 150)
returns table (
  id uuid,
  entity_type text,
  entity_id uuid,
  action text,
  occurred_at timestamptz,
  actor_user_id uuid,
  actor_display_name text,
  actor_role public.app_role,
  entity_label text,
  changed_fields jsonb,
  reason text
)
language sql stable security definer set search_path = ''
as $$
  with authorized as (
    select public.current_user_role() in ('owner'::public.app_role, 'admin'::public.app_role) as ok
  ),
  limited_events as (
    select event.*
    from public.audit_events event
    cross join authorized
    where authorized.ok
    order by event.occurred_at desc
    limit least(greatest(coalesce(requested_limit, 150), 1), 500)
  )
  select
    event.id,
    event.entity_type,
    event.entity_id,
    event.action,
    event.occurred_at,
    event.actor_user_id,
    coalesce(actor.display_name, 'Unknown user') as actor_display_name,
    actor.role as actor_role,
    coalesce(
      event.new_data ->> 'batch_code',
      event.old_data ->> 'batch_code',
      event.new_data ->> 'lot_code',
      event.old_data ->> 'lot_code',
      event.new_data ->> 'movement_code',
      event.old_data ->> 'movement_code',
      event.new_data ->> 'consolidation_code',
      event.old_data ->> 'consolidation_code',
      event.new_data ->> 'display_name',
      event.old_data ->> 'display_name',
      event.new_data ->> 'code',
      event.old_data ->> 'code',
      event.entity_id::text
    ) as entity_label,
    case
      when event.action = 'update' then coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'field', coalesce(old_field.key, new_field.key),
            'from', old_field.value,
            'to', new_field.value
          )
          order by coalesce(old_field.key, new_field.key)
        )
        from jsonb_each(coalesce(event.old_data, '{}'::jsonb)) old_field
        full join jsonb_each(coalesce(event.new_data, '{}'::jsonb)) new_field
          on new_field.key = old_field.key
        where coalesce(old_field.key, new_field.key) not in (
          'updated_at',
          'updated_by'
        )
          and old_field.value is distinct from new_field.value
      ), '[]'::jsonb)
      when event.action = 'insert' then jsonb_build_array(
        jsonb_build_object('field', 'record', 'from', null, 'to', 'created')
      )
      when event.action = 'delete' then jsonb_build_array(
        jsonb_build_object('field', 'record', 'from', 'deleted', 'to', null)
      )
      else '[]'::jsonb
    end as changed_fields,
    event.reason
  from limited_events event
  left join public.profiles actor on actor.id = event.actor_user_id
  order by event.occurred_at desc;
$$;

revoke all on function public.list_activity_events(integer) from public;
grant execute on function public.list_activity_events(integer) to authenticated;

commit;
