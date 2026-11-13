-- RLS helpers and trigger functions move out of the REST-exposed public schema,
-- so they can't be called via /rest/v1/rpc/*. Policies and triggers reference
-- functions by OID, so they keep working unchanged.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

alter function public.my_membership(uuid) set schema private;
alter function public.is_org_admin(uuid) set schema private;
alter function public.can_see_member(uuid) set schema private;
alter function public.log_commitment_change() set schema private;
alter function public.handle_new_user() set schema private;
alter function public.touch_updated_at() set schema private;
alter function public.sweep_overdue_commitments() set schema private;

alter function private.can_see_member(uuid) set search_path = private, public;
alter function private.my_membership(uuid) set search_path = private, public;
alter function private.is_org_admin(uuid) set search_path = private, public;
alter function private.log_commitment_change() set search_path = private, public;
alter function private.handle_new_user() set search_path = private, public;
alter function private.touch_updated_at() set search_path = private, public;
alter function private.sweep_overdue_commitments() set search_path = private, public;

revoke execute on all functions in schema private from public, anon;
grant execute on function private.my_membership(uuid), private.is_org_admin(uuid),
  private.can_see_member(uuid) to authenticated;
