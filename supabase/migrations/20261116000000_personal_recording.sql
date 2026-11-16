-- =============================================================================
-- Personal calls can be recorded too, for the user's own commitments.
--
--   * A personal call may now have a recording, a transcript and AI processing,
--     but still never an organisation (it never reaches the company).
--   * Commitments from personal calls belong to the user alone: org_id and
--     membership_id are null, user_id is set. Only that user can see them.
--   * profiles.record_personal_calls lets each user switch it off (default on).
--   * contacts.source records where a contact came from ('manual' | 'phone').
-- =============================================================================

-- calls: drop the old "personal calls are never recorded" check, keep "never in an org".
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.calls'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%recording_id is null%'
  loop
    execute format('alter table calls drop constraint %I', c.conname);
  end loop;
end $$;
alter table calls drop constraint if exists calls_personal_no_org;
alter table calls add constraint calls_personal_no_org check (mode = 'corporate' or org_id is null);

-- commitments: personal ones have an owner instead of an org/membership.
alter table commitments add column if not exists user_id uuid references profiles (id) on delete cascade;
update commitments c set user_id = m.user_id
from memberships m where m.id = c.membership_id and c.user_id is null;
alter table commitments alter column org_id drop not null;
alter table commitments alter column membership_id drop not null;
alter table commitments drop constraint if exists commitments_owner_scope;
alter table commitments add constraint commitments_owner_scope check (
  (org_id is not null and membership_id is not null)
  or (org_id is null and membership_id is null and user_id is not null)
);
create index if not exists commitments_personal_idx on commitments (user_id, status) where org_id is null;

-- Row-level security: a personal commitment (and its call's transcript) is visible to its owner only.
drop policy if exists commitments_read on commitments;
create policy commitments_read on commitments for select
  using ((org_id is null and user_id = auth.uid())
      or (org_id is not null and private.can_see_member(membership_id)));
drop policy if exists commitments_update on commitments;
create policy commitments_update on commitments for update
  using ((org_id is null and user_id = auth.uid())
      or (org_id is not null and private.can_see_member(membership_id)))
  with check ((org_id is null and user_id = auth.uid())
      or (org_id is not null and private.can_see_member(membership_id)));

drop policy if exists transcript_read on transcript_segments;
create policy transcript_read on transcript_segments for select
  using (exists (select 1 from calls c where c.id = call_id
                 and ((c.mode = 'personal' and c.user_id = auth.uid())
                   or (c.mode = 'corporate' and private.can_see_member(c.membership_id)))));

drop policy if exists events_read on commitment_events;
create policy events_read on commitment_events for select
  using (exists (select 1 from commitments c where c.id = commitment_id
                 and ((c.org_id is null and c.user_id = auth.uid())
                   or (c.org_id is not null and private.can_see_member(c.membership_id)))));

-- Per-user switch (default on) and contact provenance.
alter table profiles add column if not exists record_personal_calls boolean not null default true;
grant select (record_personal_calls) on profiles to authenticated;
alter table contacts add column if not exists source text not null default 'manual'
  check (source in ('manual', 'phone'));
create index if not exists contacts_owner_phone_idx on contacts (owner_id, phone_e164) where org_id is null;
