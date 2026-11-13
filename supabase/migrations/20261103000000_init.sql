-- =============================================================================
-- Commit AI — core schema
-- Calls between employees and clients, AI-extracted commitments, and the
-- accountability trail management uses to follow up.
--
-- Privacy model (enforced here, not just in the app):
--   * PERSONAL calls have org_id = NULL. They are never recorded, never
--     transcribed and are visible only to the user who made/received them.
--   * CORPORATE calls belong to an organization. The employee sees their own;
--     managers see their reports; admins see the whole org.
-- =============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums ----
create type app_mode            as enum ('personal', 'corporate');
create type member_role         as enum ('employee', 'manager', 'admin');
create type call_direction      as enum ('outbound', 'inbound');
create type call_channel        as enum ('app', 'pstn_mobile', 'pstn_landline', 'sip');
create type call_status         as enum ('ringing', 'active', 'completed', 'missed',
                                         'rejected', 'blocked_mode', 'off_duty', 'failed');
create type processing_status   as enum ('not_applicable', 'pending', 'processing', 'done', 'failed');
create type speaker_role        as enum ('employee', 'client', 'unknown');
create type commitment_owner    as enum ('employee', 'client');
create type commitment_status   as enum ('pending_review', 'open', 'in_progress', 'fulfilled',
                                         'missed', 'disputed', 'cancelled');
create type commitment_category as enum ('deliverable', 'follow_up', 'pricing', 'meeting',
                                         'information', 'support', 'other');
create type commitment_priority as enum ('low', 'medium', 'high');

-- ---------------------------------------------------------------- tables ---
create table organizations (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  corp_code             text not null unique,            -- what employees type at corporate login, e.g. "ACME"
  timezone              text not null default 'Africa/Lagos',
  recording_disclosure  text not null default
    'This call is recorded so we can follow up on everything we agree today.',
  announce_recording    boolean not null default true,
  off_duty_policy       text not null default 'voicemail'  -- 'ring' | 'voicemail' when employee is in personal mode
                        check (off_duty_policy in ('ring', 'voicemail')),
  retention_days        int not null default 365,
  created_at            timestamptz not null default now()
);

create table profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  full_name     text not null,
  avatar_url    text,
  personal_phone text,
  created_at    timestamptz not null default now()
);

create table memberships (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations (id) on delete cascade,
  user_id        uuid references profiles (id) on delete set null,  -- null until the employee activates
  employee_id    text not null,                                     -- the corporate ID
  pin_hash       text,                                              -- bcrypt(crypt) of the corporate PIN
  role           member_role not null default 'employee',
  title          text,
  department     text,
  manager_id     uuid references memberships (id) on delete set null,
  corporate_did  text,               -- the employee's direct corporate number (E.164), for GSM/landline dial-in
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (org_id, employee_id)
);
create index on memberships (user_id);
create index on memberships (corporate_did);

-- Which mode a user is in right now. The server is the source of truth for
-- call routing: a corporate-mode user is never rung for a personal call.
create table presence (
  user_id        uuid primary key references profiles (id) on delete cascade,
  mode           app_mode not null default 'personal',
  membership_id  uuid references memberships (id) on delete set null,
  updated_at     timestamptz not null default now(),
  check (mode = 'personal' or membership_id is not null)
);

create table devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles (id) on delete cascade,
  platform    text not null check (platform in ('android', 'ios')),
  push_token  text,          -- FCM
  voip_token  text,          -- APNs PushKit (iOS CallKit)
  updated_at  timestamptz not null default now(),
  unique (user_id, platform)
);

create table contacts (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid references organizations (id) on delete cascade,  -- null = personal contact
  owner_id      uuid not null references profiles (id) on delete cascade,
  name          text not null,
  company       text,
  phone_e164    text,
  app_user_id   uuid references profiles (id) on delete set null,      -- reachable app-to-app
  is_client     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index on contacts (org_id, phone_e164);

create table calls (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid references organizations (id) on delete cascade,
  mode                  app_mode not null,
  user_id               uuid not null references profiles (id) on delete cascade,  -- our employee/user
  membership_id         uuid references memberships (id) on delete set null,
  direction             call_direction not null,
  channel               call_channel not null,
  contact_id            uuid references contacts (id) on delete set null,
  counterpart_name      text,
  counterpart_number    text,
  counterpart_user_id   uuid references profiles (id) on delete set null,
  daily_room            text,
  daily_room_url        text,
  status                call_status not null default 'ringing',
  started_at            timestamptz not null default now(),
  answered_at           timestamptz,
  ended_at              timestamptz,
  duration_s            int generated always as
                          (case when ended_at is not null and answered_at is not null
                                then extract(epoch from ended_at - answered_at)::int end) stored,
  recording_id          text,
  consent_announced     boolean not null default false,
  processing            processing_status not null default 'not_applicable',
  summary               text,
  sentiment             text check (sentiment in ('positive', 'neutral', 'negative', 'mixed')),
  employee_talk_ratio   numeric(4,3),
  -- Personal calls must stay out of the corporate pipeline entirely.
  check (mode = 'corporate' or (org_id is null and recording_id is null and processing = 'not_applicable')),
  check (mode = 'personal'  or (org_id is not null and membership_id is not null))
);
create index on calls (org_id, started_at desc);
create index on calls (user_id, started_at desc);

create table transcript_segments (
  id          bigint generated always as identity primary key,
  call_id     uuid not null references calls (id) on delete cascade,
  speaker     speaker_role not null,
  text        text not null,
  offset_ms   int not null,
  created_at  timestamptz not null default now()
);
create index on transcript_segments (call_id, offset_ms);

create table commitments (
  id                 uuid primary key default gen_random_uuid(),
  org_id             uuid not null references organizations (id) on delete cascade,
  call_id            uuid references calls (id) on delete set null,
  membership_id      uuid not null references memberships (id) on delete cascade, -- accountable employee
  contact_id         uuid references contacts (id) on delete set null,
  client_name        text,
  owner              commitment_owner not null default 'employee',  -- who promised it
  title              text not null,
  detail             text,
  quote              text,                    -- the exact words, for disputes
  quote_offset_ms    int,                     -- jump-to in the recording
  due_at             timestamptz,
  due_text           text,                    -- "by Friday", as said
  category           commitment_category not null default 'other',
  priority           commitment_priority not null default 'medium',
  confidence         numeric(3,2) not null default 0.80 check (confidence between 0 and 1),
  status             commitment_status not null default 'pending_review',
  confirmed_by_employee boolean not null default false,
  completed_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on commitments (org_id, status, due_at);
create index on commitments (membership_id, status);

create table commitment_events (
  id             bigint generated always as identity primary key,
  commitment_id  uuid not null references commitments (id) on delete cascade,
  actor_id       uuid references profiles (id) on delete set null,
  kind           text not null check (kind in ('created', 'confirmed', 'status_changed', 'due_changed',
                                               'comment', 'nudge', 'reminder', 'escalated')),
  payload        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index on commitment_events (commitment_id, created_at);

-- ----------------------------------------------------- helper functions ---
create or replace function my_membership(p_org uuid)
returns memberships language sql stable security definer set search_path = public as $$
  select * from memberships where org_id = p_org and user_id = auth.uid() and active limit 1
$$;

create or replace function is_org_admin(p_org uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships
                 where org_id = p_org and user_id = auth.uid() and active and role = 'admin')
$$;

-- True when the caller may see work owned by membership p_member: it is theirs,
-- they manage it (directly or further up the chain), or they are an org admin.
create or replace function can_see_member(p_member uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with recursive chain as (
    select id, manager_id, org_id, user_id from memberships where id = p_member
    union all
    select m.id, m.manager_id, m.org_id, m.user_id
    from memberships m join chain c on m.id = c.manager_id
  )
  select exists (select 1 from chain where user_id = auth.uid())
      or exists (select 1 from memberships t
                 where t.id = p_member and is_org_admin(t.org_id))
$$;

create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger commitments_touch before update on commitments
  for each row execute function touch_updated_at();

-- Every status change lands in the audit trail automatically.
create or replace function log_commitment_change() returns trigger language plpgsql
security definer set search_path = public as $$
begin
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
create trigger commitments_audit after insert or update on commitments
  for each row execute function log_commitment_change();

-- Mark open commitments past due as missed (run from pg_cron or the API's scheduler).
create or replace function sweep_overdue_commitments() returns int language sql as $$
  with upd as (
    update commitments set status = 'missed'
    where status in ('open', 'in_progress') and due_at < now() - interval '1 hour'
    returning id
  )
  select count(*)::int from upd
$$;

-- ------------------------------------------------------- dashboard view ---
create or replace view member_reliability with (security_invoker = true) as
select
  m.id                          as membership_id,
  m.org_id,
  p.full_name,
  m.title,
  m.department,
  count(c.*) filter (where c.status in ('open', 'in_progress'))                 as open_count,
  count(c.*) filter (where c.status = 'missed')                                 as missed_count,
  count(c.*) filter (where c.status = 'fulfilled')                              as fulfilled_count,
  count(c.*) filter (where c.status = 'fulfilled' and c.completed_at <= c.due_at) as on_time_count,
  round(100.0 * count(c.*) filter (where c.status = 'fulfilled' and (c.due_at is null or c.completed_at <= c.due_at))
        / nullif(count(c.*) filter (where c.status in ('fulfilled', 'missed')), 0), 1) as reliability_pct
from memberships m
join profiles p on p.id = m.user_id
left join commitments c on c.membership_id = m.id and c.owner = 'employee'
group by m.id, p.full_name;

-- ------------------------------------------------------------------ RLS ---
alter table organizations       enable row level security;
alter table profiles            enable row level security;
alter table memberships         enable row level security;
alter table presence            enable row level security;
alter table devices             enable row level security;
alter table contacts            enable row level security;
alter table calls               enable row level security;
alter table transcript_segments enable row level security;
alter table commitments         enable row level security;
alter table commitment_events   enable row level security;

create policy org_read on organizations for select
  using ((my_membership(id)).id is not null);

create policy profile_self on profiles for all
  using (id = auth.uid()) with check (id = auth.uid());
create policy profile_colleagues on profiles for select
  using (exists (select 1 from memberships a join memberships b on a.org_id = b.org_id
                 where a.user_id = auth.uid() and b.user_id = profiles.id));

create policy members_read on memberships for select
  using ((my_membership(org_id)).id is not null);
create policy members_admin on memberships for all
  using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy presence_self on presence for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy devices_self on devices for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy contacts_personal on contacts for all
  using (org_id is null and owner_id = auth.uid())
  with check (org_id is null and owner_id = auth.uid());
create policy contacts_org on contacts for all
  using (org_id is not null and (my_membership(org_id)).id is not null)
  with check (org_id is not null and (my_membership(org_id)).id is not null);

-- Calls: personal → only me. Corporate → me, my managers, org admins.
create policy calls_read on calls for select
  using ((mode = 'personal' and user_id = auth.uid())
      or (mode = 'corporate' and can_see_member(membership_id)));

create policy transcript_read on transcript_segments for select
  using (exists (select 1 from calls c where c.id = call_id
                 and c.mode = 'corporate' and can_see_member(c.membership_id)));

create policy commitments_read on commitments for select
  using (can_see_member(membership_id));
create policy commitments_update on commitments for update
  using (can_see_member(membership_id)) with check (can_see_member(membership_id));

create policy events_read on commitment_events for select
  using (exists (select 1 from commitments c where c.id = commitment_id and can_see_member(c.membership_id)));
create policy events_comment on commitment_events for insert
  with check (kind in ('comment', 'nudge') and actor_id = auth.uid()
              and exists (select 1 from commitments c where c.id = commitment_id and can_see_member(c.membership_id)));

-- Inserts into calls / transcripts / commitments come from the backend with the
-- service-role key (it bypasses RLS), never directly from the phone.

-- Live updates for the dashboard and the employee's commitment list.
alter publication supabase_realtime add table commitments, calls;
