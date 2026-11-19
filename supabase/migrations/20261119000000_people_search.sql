-- People search: anyone with an account can find and app-call anyone else on Commit AI.
--   * profiles.discoverable = "Let people find me" (default on). When off, the user is hidden
--     from name search but can still be reached by someone who knows their exact email.
--   * Trigram index so case-insensitive name search (ilike '%q%') stays fast.
-- Search runs on the API server with the service role; clients never query profiles directly.
alter table profiles add column if not exists discoverable boolean not null default true;
grant select (discoverable) on profiles to authenticated;

create extension if not exists pg_trgm with schema extensions;
create index if not exists profiles_full_name_trgm
  on profiles using gin (full_name extensions.gin_trgm_ops);
