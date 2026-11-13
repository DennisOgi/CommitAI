-- =============================================================================
-- Production hardening
--   * calls.transcript_purged: set by the retention job (organizations.retention_days)
--   * indexes for the queries the API and scheduler run on every request / tick
--   * the audit trigger now records only direct client writes (auth.uid() set);
--     the API (service role) writes its own, richer events, so they are no
--     longer duplicated
-- =============================================================================

alter table calls add column if not exists transcript_purged boolean not null default false;

create index if not exists calls_room_idx        on calls (daily_room);
create index if not exists calls_ringing_idx     on calls (user_id, started_at desc) where status = 'ringing';
create index if not exists commitments_status_idx on commitments (status, due_at);
create index if not exists commitments_member_idx on commitments (org_id, membership_id);
create index if not exists commitments_call_idx   on commitments (call_id);
create index if not exists devices_user_idx       on devices (user_id);

-- ---------------------------------------------------------------------------
-- The corporate PIN hash must never leave the server. Column privileges hide it
-- from app users even where RLS lets them read the row.
revoke select on memberships from anon, authenticated;
grant select (id, org_id, user_id, employee_id, role, title, department, manager_id,
              corporate_did, active, created_at) on memberships to authenticated;
revoke insert, update on memberships from anon, authenticated;

-- Presence decides call routing and recording. Only the API (after checking the
-- corporate PIN / session) may change it; users can only read their own.
drop policy if exists presence_self on presence;
create policy presence_read_self on presence for select using (user_id = auth.uid());
revoke insert, update, delete on presence from anon, authenticated;

-- Commitments: users may update status/notes fields, not move them between people or orgs.
revoke update on commitments from anon, authenticated;
grant update (status, title, due_at, completed_at) on commitments to authenticated;

-- Every new auth user gets a profile, so /v1/me works right after sign-up.
create or replace function handle_new_user() returns trigger language plpgsql
security definer set search_path = public as $$
begin
  insert into profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1), 'New user'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- Helper functions are for RLS, not for calling over the REST API.
revoke execute on function my_membership(uuid), is_org_admin(uuid), can_see_member(uuid),
  sweep_overdue_commitments(), handle_new_user() from anon;
alter function touch_updated_at() set search_path = public;
alter function sweep_overdue_commitments() set search_path = public;

create or replace function log_commitment_change() returns trigger language plpgsql
security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return new;  -- service role (the API) logs its own events
  end if;
  if tg_op = 'INSERT' then
    insert into commitment_events (commitment_id, actor_id, kind, payload)
    values (new.id, auth.uid(), 'created', jsonb_build_object('title', new.title));
  elsif new.status is distinct from old.status then
    insert into commitment_events (commitment_id, actor_id, kind, payload)
    values (new.id, auth.uid(), 'status_changed', jsonb_build_object('from', old.status, 'to', new.status));
  elsif new.due_at is distinct from old.due_at then
    insert into commitment_events (commitment_id, actor_id, kind, payload)
    values (new.id, auth.uid(), 'due_changed', jsonb_build_object('from', old.due_at, 'to', new.due_at));
  end if;
  return new;
end $$;
