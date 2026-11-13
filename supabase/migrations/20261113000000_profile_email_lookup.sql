-- Email on profiles so a user can add another Commit AI user as a contact (and app-call them).
alter table profiles add column if not exists email text;
create unique index if not exists profiles_email_idx on profiles (lower(email));

update profiles p set email = lower(u.email)
from auth.users u where u.id = p.id and p.email is null;

create or replace function private.handle_new_user() returns trigger language plpgsql
security definer set search_path = private, public as $$
begin
  insert into profiles (id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1), 'New user'),
          lower(new.email))
  on conflict (id) do update set email = excluded.email;
  return new;
end $$;

-- Emails are only resolved server-side (service role); app users can't list each other's emails.
revoke select on profiles from anon, authenticated;
grant select (id, full_name, avatar_url, personal_phone, created_at) on profiles to authenticated;
