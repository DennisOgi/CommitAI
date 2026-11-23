-- Company self-registration and employee onboarding.
--   * memberships.full_name: the employee's name as the admin typed it, shown before they join.
--   * memberships.invite_email: the email the admin added them with. When someone signs up with
--     that email, the app offers "You've been added to <company> — Join" (they pick their PIN).
--   * memberships.must_change_pin: first-time / reset PINs must be changed after the first sign-in.
-- All writes go through the API server (service role); clients never write memberships directly.
alter table memberships add column if not exists full_name text;
alter table memberships add column if not exists invite_email text;
alter table memberships add column if not exists must_change_pin boolean not null default false;

create index if not exists memberships_invite_email on memberships (lower(invite_email))
  where invite_email is not null;

-- Existing rows: carry the linked profile's name and email over, so the team list reads well.
update memberships m
   set full_name = coalesce(m.full_name, p.full_name),
       invite_email = coalesce(m.invite_email, p.email)
  from profiles p
 where p.id = m.user_id;
