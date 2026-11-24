-- QueueCare hospital queue schema for Supabase Postgres.
-- All app tables have RLS enabled and no client policies: the Python API uses
-- the service key after it verifies the caller's Supabase Auth JWT and role.

create table if not exists public.hq_departments (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.hq_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  phone text,
  role text not null default 'patient' check (role in ('patient', 'doctor', 'staff', 'admin')),
  department_id uuid references public.hq_departments(id) on delete set null,
  specialty text,
  license_number text,
  room text,
  consultation_hours text,
  is_active boolean not null default true,
  approval_status text not null default 'approved' check (approval_status in ('pending', 'approved', 'rejected')),
  signup_nonce uuid,
  signup_requested_role text check (signup_requested_role in ('patient', 'doctor', 'staff', 'admin')),
  signup_finalized boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.hq_profiles
  add column if not exists approval_status text not null default 'approved'
  check (approval_status in ('pending', 'approved', 'rejected'));
alter table public.hq_profiles add column if not exists signup_nonce uuid;
alter table public.hq_profiles add column if not exists signup_requested_role text
  check (signup_requested_role in ('patient', 'doctor', 'staff', 'admin'));
alter table public.hq_profiles add column if not exists signup_finalized boolean not null default true;

create index if not exists hq_profiles_role_idx on public.hq_profiles(role, is_active);
create index if not exists hq_profiles_department_idx on public.hq_profiles(department_id);
create index if not exists hq_profiles_approval_idx on public.hq_profiles(approval_status, created_at);

-- Finalize a SELF-SERVICE signup. Only patients can register themselves: the
-- requested role in Auth metadata is ignored and nothing here can ever produce
-- a doctor, staff, nurse or admin account. Those accounts are created only by
-- an authenticated administrator (POST /api/v1/admin/users) or, for the very
-- first administrator, by backend/scripts/create_admin.py using the service key.
drop function if exists public.hq_finalize_signup(uuid, text, text, text, uuid, text);
drop function if exists public.hq_finalize_signup(uuid, text, text, text, text);
create or replace function public.hq_finalize_patient_signup(
  p_user_id uuid,
  p_full_name text,
  p_email text,
  p_signup_nonce uuid,
  p_phone text default null
)
returns public.hq_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.hq_profiles;
begin
  if not exists (
    select 1 from public.hq_profiles
    where id = p_user_id
      and signup_nonce = p_signup_nonce
      and signup_finalized = false
  ) then
    raise exception 'Signup could not be verified';
  end if;

  update public.hq_profiles
  set full_name = p_full_name,
      email = p_email,
      phone = coalesce(p_phone, phone),
      role = 'patient',
      approval_status = 'approved',
      is_active = true,
      signup_finalized = true,
      signup_nonce = null,
      signup_requested_role = null,
      updated_at = pg_catalog.now()
  where id = p_user_id
  returning * into v_profile;

  if not found then
    raise exception 'Signup profile was not created';
  end if;
  return v_profile;
end;
$$;

revoke all on function public.hq_finalize_patient_signup(uuid, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.hq_finalize_patient_signup(uuid, text, text, uuid, text) to service_role;

create table if not exists public.hq_doctor_availability (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.hq_profiles(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  is_break boolean not null default false,
  created_at timestamptz not null default now(),
  check (end_time > start_time),
  unique (doctor_id, weekday, start_time, end_time)
);

create table if not exists public.hq_doctor_time_off (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.hq_profiles(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_by uuid references public.hq_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.hq_queue_rules (
  id uuid primary key default gen_random_uuid(),
  department_id uuid not null unique references public.hq_departments(id) on delete cascade,
  slot_duration_minutes integer not null default 15 check (slot_duration_minutes between 5 and 240),
  max_patients_per_day integer not null default 40 check (max_patients_per_day between 1 and 1000),
  allow_walk_ins boolean not null default true,
  walk_in_policy text not null default 'after_booked',
  updated_by uuid references public.hq_profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.hq_appointments (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid references public.hq_profiles(id) on delete set null,
  patient_name text not null,
  patient_phone text,
  doctor_id uuid not null references public.hq_profiles(id) on delete restrict,
  department_id uuid not null references public.hq_departments(id) on delete restrict,
  appointment_date date not null,
  start_time time not null,
  queue_number integer not null check (queue_number > 0),
  source text not null default 'appointment' check (source in ('appointment', 'walk_in')),
  status text not null default 'booked' check (status in ('booked', 'checked_in', 'called', 'in_progress', 'completed', 'no_show', 'cancelled', 'doctor_leave')),
  checkin_code uuid not null default gen_random_uuid() unique,
  notes text,
  created_by uuid references public.hq_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (doctor_id, appointment_date, queue_number)
);

create index if not exists hq_appointments_patient_idx on public.hq_appointments(patient_id, appointment_date desc);
create index if not exists hq_appointments_queue_idx on public.hq_appointments(doctor_id, appointment_date, status, queue_number);
create index if not exists hq_appointments_department_idx on public.hq_appointments(department_id, appointment_date, status);

-- Medical image bytes live in a private Storage bucket. Postgres stores only
-- ownership, visit association, and display metadata; the API streams images.
create table if not exists public.hq_medical_records (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.hq_profiles(id) on delete cascade,
  uploaded_by uuid not null references public.hq_profiles(id) on delete restrict,
  appointment_id uuid references public.hq_appointments(id) on delete set null,
  record_type text not null check (record_type in ('prescription', 'report', 'other')),
  title text not null default 'Medical image' check (char_length(title) between 1 and 160),
  original_filename text not null default 'medical-image' check (char_length(original_filename) between 1 and 200),
  content_type text not null default 'image/jpeg' check (content_type = 'image/jpeg'),
  file_size_bytes integer not null check (file_size_bytes between 1 and 12582912),
  storage_path text not null unique,
  created_at timestamptz not null default now(),
  check (storage_path = patient_id::text || '/' || id::text || '.jpg')
);
create index if not exists hq_medical_records_patient_idx
  on public.hq_medical_records(patient_id, created_at desc);
create index if not exists hq_medical_records_uploaded_by_idx
  on public.hq_medical_records(uploaded_by);
create index if not exists hq_medical_records_appointment_idx
  on public.hq_medical_records(appointment_id) where appointment_id is not null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('medical-records', 'medical-records', false, 12582912, array['image/jpeg'])
on conflict (id) do update set
  name = excluded.name,
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.hq_queue_events (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.hq_appointments(id) on delete cascade,
  actor_id uuid references public.hq_profiles(id) on delete set null,
  event_type text not null check (event_type in ('booked', 'walk_in_created', 'checked_in', 'called', 'started', 'completed', 'no_show', 'cancelled', 'rescheduled')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists hq_queue_events_appointment_idx on public.hq_queue_events(appointment_id, created_at desc);

create table if not exists public.hq_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.hq_profiles(id) on delete cascade,
  title text not null,
  message text not null,
  category text not null default 'info' check (category in ('info', 'success', 'warning', 'error')),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists hq_notifications_recipient_idx on public.hq_notifications(recipient_id, is_read, created_at desc);

create table if not exists public.hq_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  message text not null,
  target_role text check (target_role in ('patient', 'doctor', 'staff', 'admin')),
  department_id uuid references public.hq_departments(id) on delete set null,
  published_by uuid references public.hq_profiles(id) on delete set null,
  published_at timestamptz not null default now()
);

create table if not exists public.hq_feedback (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.hq_appointments(id) on delete cascade,
  patient_id uuid not null references public.hq_profiles(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

-- Auth-created profiles are always created as inactive, unfinalized PATIENT rows.
-- Role metadata supplied by a client is stored but never trusted.
create or replace function public.hq_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.hq_profiles (id, full_name, email, role, approval_status, is_active, signup_nonce, signup_requested_role, signup_finalized)
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

revoke all on function public.hq_handle_new_auth_user() from public, anon, authenticated;
drop trigger if exists hq_on_auth_user_created on auth.users;
create trigger hq_on_auth_user_created
  after insert on auth.users
  for each row execute function public.hq_handle_new_auth_user();

-- Locks one doctor/day while allocating a token, so concurrent bookings cannot
-- create duplicate queue numbers. The API is responsible for authorization.
create or replace function public.hq_book_appointment(
  p_patient_id uuid,
  p_doctor_id uuid,
  p_appointment_date date,
  p_start_time time,
  p_source text default 'appointment',
  p_patient_name text default null,
  p_patient_phone text default null,
  p_created_by uuid default null
)
returns public.hq_appointments
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_department_id uuid;
  v_queue_number integer;
  v_name text;
  v_phone text;
  v_status text;
  v_slot_minutes integer := 15;
  v_max_patients integer := 40;
  v_allow_walk_ins boolean := true;
  v_has_schedule boolean := false;
  v_scheduled boolean := false;
  v_active_count integer := 0;
  v_appointment public.hq_appointments;
begin
  if p_source not in ('appointment', 'walk_in') then
    raise exception 'Invalid appointment source';
  end if;
  select department_id into v_department_id
  from public.hq_profiles
  where id = p_doctor_id and role = 'doctor' and is_active = true;
  if v_department_id is null then
    raise exception 'Doctor is unavailable';
  end if;
  select coalesce(r.slot_duration_minutes, 15), coalesce(r.max_patients_per_day, 40), coalesce(r.allow_walk_ins, true)
  into v_slot_minutes, v_max_patients, v_allow_walk_ins
  from (select 1) as defaults
  left join public.hq_queue_rules as r on r.department_id = v_department_id;
  if p_source = 'walk_in' and not v_allow_walk_ins then raise exception 'Walk-ins are disabled for this department'; end if;
  select count(*) into v_active_count
  from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_appointment_date
    and status not in ('cancelled', 'no_show');
  if v_active_count >= v_max_patients then raise exception 'The queue is full for this day'; end if;

  select exists(select 1 from public.hq_doctor_availability where doctor_id = p_doctor_id)
  into v_has_schedule;
  if v_has_schedule then
    select exists(
      select 1 from public.hq_doctor_availability
      where doctor_id = p_doctor_id
        and weekday = (extract(isodow from p_appointment_date)::smallint - 1)
        and is_break = false
        and p_start_time >= start_time
        and p_start_time + make_interval(mins => v_slot_minutes) <= end_time
    ) into v_scheduled;
    if not v_scheduled then raise exception 'The selected time is outside the doctor schedule'; end if;
  end if;
  if p_patient_id is not null then
    select full_name, phone into v_name, v_phone
    from public.hq_profiles
    where id = p_patient_id and role = 'patient' and is_active = true;
    if not found then raise exception 'Patient is unavailable'; end if;
  end if;
  v_name := coalesce(nullif(trim(p_patient_name), ''), v_name, 'Walk-in patient');
  v_phone := coalesce(nullif(trim(p_patient_phone), ''), v_phone);
  if p_source = 'walk_in' then v_status := 'checked_in'; else v_status := 'booked'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_doctor_id::text || p_appointment_date::text, 0));
  select coalesce(max(queue_number), 0) + 1 into v_queue_number
  from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_appointment_date;

  insert into public.hq_appointments (
    patient_id, patient_name, patient_phone, doctor_id, department_id,
    appointment_date, start_time, queue_number, source, status, created_by
  ) values (
    p_patient_id, v_name, v_phone, p_doctor_id, v_department_id,
    p_appointment_date, p_start_time, v_queue_number, p_source, v_status, p_created_by
  ) returning * into v_appointment;

  insert into public.hq_queue_events (appointment_id, actor_id, event_type)
  values (v_appointment.id, p_created_by, case when p_source = 'walk_in' then 'walk_in_created' else 'booked' end);
  return v_appointment;
end;
$$;

revoke all on function public.hq_book_appointment(uuid, uuid, date, time, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.hq_book_appointment(uuid, uuid, date, time, text, text, text, uuid) to service_role;

create or replace function public.hq_reschedule_appointment(
  p_appointment_id uuid,
  p_doctor_id uuid,
  p_appointment_date date,
  p_start_time time,
  p_actor_id uuid
)
returns public.hq_appointments
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_old public.hq_appointments;
  v_new public.hq_appointments;
begin
  select * into v_old from public.hq_appointments where id = p_appointment_id for update;
  if not found or v_old.status not in ('booked', 'checked_in') then
    raise exception 'This appointment can no longer be rescheduled';
  end if;
  update public.hq_appointments
  set status = 'cancelled', updated_at = now()
  where id = p_appointment_id;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type)
  values (p_appointment_id, p_actor_id, 'rescheduled');

  v_new := public.hq_book_appointment(
    v_old.patient_id, p_doctor_id, p_appointment_date, p_start_time,
    v_old.source, v_old.patient_name, v_old.patient_phone, p_actor_id
  );
  if v_old.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_old.patient_id, 'Appointment rescheduled', 'Your appointment time has been updated.', 'info');
  end if;
  return v_new;
end;
$$;

revoke all on function public.hq_reschedule_appointment(uuid, uuid, date, time, uuid) from public, anon, authenticated;
grant execute on function public.hq_reschedule_appointment(uuid, uuid, date, time, uuid) to service_role;

create or replace function public.hq_call_next_patient(p_doctor_id uuid, p_actor_id uuid, p_queue_date date)
returns public.hq_appointments
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_appointment public.hq_appointments;
  v_previous_id uuid;
begin
  update public.hq_appointments
  set status = 'in_progress', updated_at = now()
  where id = (
    select id from public.hq_appointments
    where doctor_id = p_doctor_id and appointment_date = p_queue_date and status = 'called'
    order by queue_number desc limit 1 for update skip locked
  )
  returning id into v_previous_id;
  if v_previous_id is not null then
    insert into public.hq_queue_events (appointment_id, actor_id, event_type)
    values (v_previous_id, p_actor_id, 'started');
  end if;

  select * into v_appointment
  from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_queue_date and status = 'checked_in'
  order by queue_number
  for update skip locked
  limit 1;
  if not found then return null; end if;

  update public.hq_appointments
  set status = 'called', updated_at = now()
  where id = v_appointment.id
  returning * into v_appointment;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type)
  values (v_appointment.id, p_actor_id, 'called');
  if v_appointment.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_appointment.patient_id, 'It is your turn', 'Please go to your consultation room.', 'success');
  end if;
  return v_appointment;
end;
$$;

revoke all on function public.hq_call_next_patient(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.hq_call_next_patient(uuid, uuid, date) to service_role;

-- Authenticated app clients cannot call the data API directly. The Python API
-- uses its server-only service key and enforces user/role ownership per route.
alter table public.hq_departments enable row level security;
alter table public.hq_profiles enable row level security;
alter table public.hq_doctor_availability enable row level security;
alter table public.hq_doctor_time_off enable row level security;
alter table public.hq_queue_rules enable row level security;
alter table public.hq_appointments enable row level security;
alter table public.hq_queue_events enable row level security;
alter table public.hq_notifications enable row level security;
alter table public.hq_announcements enable row level security;
alter table public.hq_feedback enable row level security;
alter table public.hq_medical_records enable row level security;

revoke all on public.hq_departments, public.hq_profiles, public.hq_doctor_availability,
  public.hq_doctor_time_off, public.hq_queue_rules, public.hq_appointments,
  public.hq_queue_events, public.hq_notifications, public.hq_announcements,
  public.hq_feedback, public.hq_medical_records from anon, authenticated;
grant all on public.hq_departments, public.hq_profiles, public.hq_doctor_availability,
  public.hq_doctor_time_off, public.hq_queue_rules, public.hq_appointments,
  public.hq_queue_events, public.hq_notifications, public.hq_announcements,
  public.hq_feedback, public.hq_medical_records to service_role;

insert into public.hq_departments (name, code, description)
values
  ('Cardiology', 'CARD', 'Heart and cardiovascular care'),
  ('Orthopedics', 'ORTHO', 'Bone and joint care'),
  ('Pediatrics', 'PEDS', 'Care for children'),
  ('Eye Care', 'EYE', 'Ophthalmology and vision care'),
  ('ENT', 'ENT', 'Ear, nose, and throat care')
on conflict (code) do nothing;

insert into public.hq_queue_rules (department_id)
select id from public.hq_departments
on conflict (department_id) do nothing;
