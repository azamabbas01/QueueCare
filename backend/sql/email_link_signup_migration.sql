-- SUPERSEDED: this change is already part of schema.sql. Only run it on a database created from the very first schema; then run 002_queuecare_v2.sql.
-- Apply this migration to an existing QueueCare database before deploying
-- email-link signup. The Auth trigger must persist the server-requested role
-- and nonce before Supabase sends the confirmation email.
alter table public.hq_profiles add column if not exists signup_nonce uuid;
alter table public.hq_profiles add column if not exists signup_requested_role text
  check (signup_requested_role in ('patient', 'doctor', 'staff', 'admin'));
alter table public.hq_profiles add column if not exists signup_finalized boolean not null default true;

create or replace function public.hq_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.hq_profiles (
    id, full_name, email, role, approval_status, is_active,
    signup_nonce, signup_requested_role, signup_finalized
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.email, ''),
    'patient',
    'pending',
    false,
    case
      when coalesce(new.raw_user_meta_data ->> 'signup_nonce', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (new.raw_user_meta_data ->> 'signup_nonce')::uuid
      else null
    end,
    case
      when new.raw_user_meta_data ->> 'signup_requested_role' in ('patient', 'doctor', 'staff', 'admin')
      then new.raw_user_meta_data ->> 'signup_requested_role'
      else null
    end,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.hq_handle_new_auth_user()
  from public, anon, authenticated;
