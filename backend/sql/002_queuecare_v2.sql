-- QueueCare v2 migration. Run AFTER schema.sql (safe to re-run).
--
--   * nurse role (triage vitals) and admin-created-only privileged accounts
--   * forced password change, national-id / phone duplicate detection support
--   * triage priority, late-arrival requeue, skip / recall, referral
--   * append-only audit log, break-glass emergency access, consent records
--   * immutable identity photos with a supervised admin unlock path
--   * clinical data (vitals, consultations, prescriptions, follow-ups) in tables
--     that are separate from administrative data (appointments, tokens)
--   * SMS fallback outbox and queue-alert de-duplication
--
-- Every table has RLS enabled and NO client policy: only the Python API (service
-- key, after verifying the caller's JWT and role) can read or write them.

begin;

-- ---------------------------------------------------------------- roles ----
alter table public.hq_profiles drop constraint if exists hq_profiles_role_check;
alter table public.hq_profiles
  add constraint hq_profiles_role_check
  check (role in ('patient', 'doctor', 'staff', 'nurse', 'admin'));
alter table public.hq_announcements drop constraint if exists hq_announcements_target_role_check;
alter table public.hq_announcements
  add constraint hq_announcements_target_role_check
  check (target_role is null or target_role in ('patient', 'doctor', 'staff', 'nurse', 'admin'));

alter table public.hq_profiles
  add column if not exists must_change_password boolean not null default false,
  add column if not exists national_id_hash text,
  add column if not exists national_id_last4 text,
  add column if not exists dob date,
  add column if not exists sms_opt_in boolean not null default true,
  add column if not exists preferred_language text not null default 'en',
  add column if not exists signup_consents jsonb,
  add column if not exists last_login_at timestamptz,
  add column if not exists mfa_enroll_until timestamptz;
alter table public.hq_profiles drop constraint if exists hq_profiles_language_check;
alter table public.hq_profiles
  add constraint hq_profiles_language_check check (preferred_language in ('en', 'ur'));

create unique index if not exists hq_profiles_national_id_uidx
  on public.hq_profiles (national_id_hash)
  where national_id_hash is not null and role = 'patient';
create index if not exists hq_profiles_patient_phone_idx
  on public.hq_profiles (phone) where role = 'patient' and phone is not null;

-- ----------------------------------------------------------- dependents ----
create table if not exists public.hq_dependents (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.hq_profiles(id) on delete cascade,
  full_name text not null check (char_length(btrim(full_name)) between 2 and 120),
  relation text not null default 'child' check (relation in ('child', 'parent', 'spouse', 'other')),
  dob date,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists hq_dependents_guardian_idx on public.hq_dependents (guardian_id) where is_active;

-- ---------------------------------------------------------- appointments ----
alter table public.hq_appointments drop constraint if exists hq_appointments_status_check;
alter table public.hq_appointments
  add constraint hq_appointments_status_check
  check (status in ('booked', 'checked_in', 'called', 'in_progress', 'completed',
                    'no_show', 'cancelled', 'doctor_leave', 'skipped'));

alter table public.hq_appointments
  add column if not exists priority text not null default 'routine',
  add column if not exists priority_reason text,
  add column if not exists priority_set_by uuid references public.hq_profiles(id) on delete set null,
  add column if not exists queue_sort integer,
  add column if not exists is_late boolean not null default false,
  add column if not exists recall_count smallint not null default 0,
  add column if not exists checked_in_at timestamptz,
  add column if not exists called_at timestamptz,
  add column if not exists started_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists skipped_at timestamptz,
  add column if not exists triage_status text not null default 'pending',
  add column if not exists triage_done_at timestamptz,
  add column if not exists dependent_id uuid references public.hq_dependents(id) on delete set null,
  add column if not exists referred_from_doctor_id uuid references public.hq_profiles(id) on delete set null,
  add column if not exists follow_up_of uuid references public.hq_appointments(id) on delete set null;

alter table public.hq_appointments drop constraint if exists hq_appointments_priority_check;
alter table public.hq_appointments
  add constraint hq_appointments_priority_check check (priority in ('emergency', 'urgent', 'routine'));
alter table public.hq_appointments drop constraint if exists hq_appointments_triage_check;
alter table public.hq_appointments
  add constraint hq_appointments_triage_check check (triage_status in ('pending', 'done', 'skipped'));
alter table public.hq_appointments drop constraint if exists hq_appointments_priority_reason_check;
alter table public.hq_appointments
  add constraint hq_appointments_priority_reason_check
  check (priority = 'routine' or char_length(btrim(coalesce(priority_reason, ''))) >= 3);

update public.hq_appointments set queue_sort = queue_number where queue_sort is null;

create or replace function public.hq_set_queue_sort()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.queue_sort is null then new.queue_sort := new.queue_number; end if;
  return new;
end $$;
drop trigger if exists hq_appointments_queue_sort on public.hq_appointments;
create trigger hq_appointments_queue_sort before insert on public.hq_appointments
  for each row execute function public.hq_set_queue_sort();

create index if not exists hq_appointments_order_idx
  on public.hq_appointments (doctor_id, appointment_date, status, queue_sort);

create or replace function public.hq_priority_rank(p text)
returns integer language sql immutable as
$$ select case p when 'emergency' then 0 when 'urgent' then 1 else 2 end $$;

alter table public.hq_queue_rules
  add column if not exists grace_minutes integer not null default 10 check (grace_minutes between 1 and 120),
  add column if not exists late_after_minutes integer not null default 15 check (late_after_minutes between 1 and 240);

alter table public.hq_queue_events drop constraint if exists hq_queue_events_event_type_check;
alter table public.hq_queue_events
  add constraint hq_queue_events_event_type_check
  check (event_type in ('booked', 'walk_in_created', 'checked_in', 'called', 'started', 'completed',
                        'no_show', 'cancelled', 'rescheduled', 'late_requeued', 'skipped', 'recalled',
                        'referred', 'priority_changed', 'triage_done'));

-- ----------------------------------------------------- audit (append-only) ----
create table if not exists public.hq_audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  actor_role text,
  actor_name text,
  action text not null,
  target_type text,
  target_id text,
  patient_id uuid,
  details jsonb not null default '{}'::jsonb,
  ip text,
  success boolean not null default true
);
create index if not exists hq_audit_at_idx on public.hq_audit_log (at desc);
create index if not exists hq_audit_actor_idx on public.hq_audit_log (actor_id, at desc);
create index if not exists hq_audit_patient_idx on public.hq_audit_log (patient_id, at desc) where patient_id is not null;
create index if not exists hq_audit_action_idx on public.hq_audit_log (action, at desc);

create or replace function public.hq_audit_immutable()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'The audit log is append-only.' using errcode = 'QC003';
end $$;
drop trigger if exists hq_audit_no_change on public.hq_audit_log;
create trigger hq_audit_no_change before update or delete on public.hq_audit_log
  for each row execute function public.hq_audit_immutable();
drop trigger if exists hq_audit_no_truncate on public.hq_audit_log;
create trigger hq_audit_no_truncate before truncate on public.hq_audit_log
  for each statement execute function public.hq_audit_immutable();

-- ---------------------------------------------------------------- consent ----
create table if not exists public.hq_consents (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid references public.hq_profiles(id) on delete cascade,
  appointment_id uuid references public.hq_appointments(id) on delete cascade,
  kind text not null check (kind in ('terms', 'data_use', 'photo')),
  granted boolean not null,
  policy_version text not null default '2026-11',
  recorded_by uuid references public.hq_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (patient_id is not null or appointment_id is not null)
);
create index if not exists hq_consents_patient_idx on public.hq_consents (patient_id, kind, created_at desc);
create index if not exists hq_consents_appointment_idx on public.hq_consents (appointment_id, kind, created_at desc);

-- ----------------------------------------------------- clinical data tables ----
create table if not exists public.hq_triage_vitals (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.hq_appointments(id) on delete cascade,
  recorded_by uuid not null references public.hq_profiles(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  temp_c numeric(4,1) check (temp_c is null or temp_c between 30 and 45),
  pulse integer check (pulse is null or pulse between 20 and 260),
  bp_systolic integer check (bp_systolic is null or bp_systolic between 40 and 280),
  bp_diastolic integer check (bp_diastolic is null or bp_diastolic between 20 and 200),
  spo2 integer check (spo2 is null or spo2 between 40 and 100),
  resp_rate integer check (resp_rate is null or resp_rate between 4 and 80),
  weight_kg numeric(5,1) check (weight_kg is null or weight_kg between 0.5 and 400),
  height_cm numeric(5,1) check (height_cm is null or height_cm between 20 and 260),
  pain_score smallint check (pain_score is null or pain_score between 0 and 10),
  chief_complaint text check (chief_complaint is null or char_length(chief_complaint) <= 500),
  notes text check (notes is null or char_length(notes) <= 1000)
);
create index if not exists hq_triage_vitals_appt_idx on public.hq_triage_vitals (appointment_id, recorded_at desc);

create table if not exists public.hq_consultations (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.hq_appointments(id) on delete cascade,
  patient_id uuid references public.hq_profiles(id) on delete set null,
  doctor_id uuid not null references public.hq_profiles(id) on delete restrict,
  note_text text not null default '' check (char_length(note_text) <= 20000),
  note_source text not null default 'typed' check (note_source in ('typed', 'dictated', 'mixed')),
  diagnosis text check (diagnosis is null or char_length(diagnosis) <= 500),
  summary_en text check (summary_en is null or char_length(summary_en) <= 4000),
  summary_ur text check (summary_ur is null or char_length(summary_ur) <= 4000),
  instructions_en text check (instructions_en is null or char_length(instructions_en) <= 2000),
  instructions_ur text check (instructions_ur is null or char_length(instructions_ur) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hq_prescriptions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.hq_appointments(id) on delete cascade,
  patient_id uuid references public.hq_profiles(id) on delete set null,
  doctor_id uuid not null references public.hq_profiles(id) on delete restrict,
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) <= 30),
  advice text check (advice is null or char_length(advice) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hq_prescriptions_patient_idx on public.hq_prescriptions (patient_id, created_at desc);

create table if not exists public.hq_followups (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.hq_appointments(id) on delete cascade,
  patient_id uuid not null references public.hq_profiles(id) on delete cascade,
  doctor_id uuid not null references public.hq_profiles(id) on delete cascade,
  dependent_id uuid references public.hq_dependents(id) on delete set null,
  suggested_date date not null,
  note text check (note is null or char_length(note) <= 500),
  status text not null default 'open' check (status in ('open', 'booked', 'dismissed')),
  booked_appointment_id uuid references public.hq_appointments(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists hq_followups_patient_idx on public.hq_followups (patient_id, status, suggested_date);

-- ------------------------------------------------------- identity photos ----
create table if not exists public.hq_identity_photos (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid unique references public.hq_profiles(id) on delete cascade,
  appointment_id uuid unique references public.hq_appointments(id) on delete cascade,
  storage_path text not null unique,
  status text not null default 'pending' check (status in ('pending', 'confirmed')),
  locked boolean not null default false,
  created_by uuid references public.hq_profiles(id) on delete set null,
  confirmed_by uuid references public.hq_profiles(id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  check ((patient_id is not null) <> (appointment_id is not null)),
  check (not locked or status = 'confirmed')
);

create table if not exists public.hq_identity_photo_unlocks (
  id uuid primary key default gen_random_uuid(),
  photo_id uuid not null,
  previous_storage_path text not null,
  unlocked_by uuid not null references public.hq_profiles(id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) >= 10),
  unlocked_at timestamptz not null default now()
);

create or replace function public.hq_identity_photo_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then
    if old.locked and coalesce(current_setting('hq.photo_unlock', true), '') <> 'on' then
      raise exception 'A confirmed identity photo is locked.' using errcode = 'QC002';
    end if;
    return old;
  end if;
  if old.locked and coalesce(current_setting('hq.photo_unlock', true), '') <> 'on' then
    if new.storage_path is distinct from old.storage_path
       or new.patient_id is distinct from old.patient_id
       or new.appointment_id is distinct from old.appointment_id
       or new.locked is distinct from old.locked
       or new.status is distinct from old.status then
      raise exception 'A confirmed identity photo is locked. Ask an administrator to unlock it.' using errcode = 'QC002';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists hq_identity_photo_immutable on public.hq_identity_photos;
create trigger hq_identity_photo_immutable before update or delete on public.hq_identity_photos
  for each row execute function public.hq_identity_photo_guard();

create or replace function public.hq_unlock_identity_photo(p_photo_id uuid, p_admin_id uuid, p_reason text)
returns public.hq_identity_photos
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_photo public.hq_identity_photos;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Give a reason of at least 10 characters.' using errcode = 'QC001';
  end if;
  if not exists (select 1 from public.hq_profiles where id = p_admin_id and role = 'admin' and is_active) then
    raise exception 'Only an active administrator can unlock an identity photo.' using errcode = 'QC001';
  end if;
  select * into v_photo from public.hq_identity_photos where id = p_photo_id for update;
  if not found then raise exception 'Photo not found.' using errcode = 'QC001'; end if;
  if not v_photo.locked then raise exception 'This photo is not locked.' using errcode = 'QC001'; end if;
  insert into public.hq_identity_photo_unlocks (photo_id, previous_storage_path, unlocked_by, reason)
  values (v_photo.id, v_photo.storage_path, p_admin_id, btrim(p_reason));
  perform set_config('hq.photo_unlock', 'on', true);
  update public.hq_identity_photos
  set locked = false, status = 'pending', confirmed_by = null, confirmed_at = null
  where id = p_photo_id returning * into v_photo;
  perform set_config('hq.photo_unlock', 'off', true);
  insert into public.hq_audit_log (actor_id, actor_role, action, target_type, target_id, patient_id, details)
  values (p_admin_id, 'admin', 'identity_photo.unlock', 'identity_photo', p_photo_id::text, v_photo.patient_id,
          jsonb_build_object('reason', btrim(p_reason)));
  return v_photo;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('identity-photos', 'identity-photos', false, 3145728, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- -------------------------------------------------------------- break-glass ----
create table if not exists public.hq_break_glass (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.hq_profiles(id) on delete restrict,
  patient_id uuid not null references public.hq_profiles(id) on delete cascade,
  reason text not null check (char_length(btrim(reason)) between 15 and 500),
  opened_at timestamptz not null default now(),
  expires_at timestamptz not null,
  closed_at timestamptz,
  reviewed_by uuid references public.hq_profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_outcome text check (review_outcome in ('appropriate', 'inappropriate')),
  review_note text check (review_note is null or char_length(review_note) <= 1000)
);
create index if not exists hq_break_glass_review_idx on public.hq_break_glass (opened_at desc) where reviewed_at is null;
create index if not exists hq_break_glass_doctor_idx on public.hq_break_glass (doctor_id, opened_at desc);

create or replace function public.hq_break_glass_open(
  p_doctor_id uuid, p_patient_id uuid, p_reason text, p_minutes integer default 30
)
returns public.hq_break_glass
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_doctor public.hq_profiles;
  v_row public.hq_break_glass;
  v_recent integer;
begin
  select * into v_doctor from public.hq_profiles where id = p_doctor_id and role = 'doctor' and is_active;
  if not found then raise exception 'Only an active doctor can use emergency access.' using errcode = 'QC001'; end if;
  if not exists (select 1 from public.hq_profiles where id = p_patient_id and role = 'patient' and is_active) then
    raise exception 'Patient not found.' using errcode = 'QC001';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 15 then
    raise exception 'Describe the emergency in at least 15 characters.' using errcode = 'QC001';
  end if;
  if p_minutes < 5 or p_minutes > 60 then
    raise exception 'Emergency access lasts between 5 and 60 minutes.' using errcode = 'QC001';
  end if;
  select count(*) into v_recent from public.hq_break_glass
  where doctor_id = p_doctor_id and opened_at > now() - interval '24 hours';
  if v_recent >= 10 then
    raise exception 'Too many emergency accesses today. Contact an administrator.' using errcode = 'QC001';
  end if;

  insert into public.hq_break_glass (doctor_id, patient_id, reason, expires_at)
  values (p_doctor_id, p_patient_id, btrim(p_reason), now() + make_interval(mins => p_minutes))
  returning * into v_row;

  insert into public.hq_audit_log (actor_id, actor_role, actor_name, action, target_type, target_id, patient_id, details)
  values (p_doctor_id, 'doctor', v_doctor.full_name, 'break_glass.open', 'break_glass', v_row.id::text, p_patient_id,
          jsonb_build_object('reason', v_row.reason, 'expires_at', v_row.expires_at));

  insert into public.hq_notifications (recipient_id, title, message, category)
  values (p_patient_id, 'Your records were opened in an emergency',
          'Dr. ' || v_doctor.full_name || ' opened your records under emergency access. Reason recorded: ' || v_row.reason,
          'warning');
  insert into public.hq_notifications (recipient_id, title, message, category)
  select id, 'Break-glass access needs review',
         'Dr. ' || v_doctor.full_name || ' used emergency access. Open Security → Break-glass to review it.', 'warning'
  from public.hq_profiles where role = 'admin' and is_active;
  return v_row;
end $$;

create or replace function public.hq_has_break_glass(p_doctor_id uuid, p_patient_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.hq_break_glass
                 where doctor_id = p_doctor_id and patient_id = p_patient_id
                   and closed_at is null and expires_at > now())
$$;

-- --------------------------------------------------- notifications fallback ----
create table if not exists public.hq_sms_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid references public.hq_profiles(id) on delete cascade,
  phone text not null,
  body text not null check (char_length(body) <= 320),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists hq_sms_pending_idx on public.hq_sms_outbox (created_at) where status = 'pending';

create table if not exists public.hq_queue_alerts (
  appointment_id uuid not null references public.hq_appointments(id) on delete cascade,
  threshold integer not null,
  created_at timestamptz not null default now(),
  primary key (appointment_id, threshold)
);

-- -------------------------------------------------------- queue functions ----
drop function if exists public.hq_book_appointment(uuid, uuid, date, time, text, text, text, uuid);
create or replace function public.hq_book_appointment(
  p_patient_id uuid,
  p_doctor_id uuid,
  p_appointment_date date,
  p_start_time time,
  p_source text default 'appointment',
  p_patient_name text default null,
  p_patient_phone text default null,
  p_created_by uuid default null,
  p_dependent_id uuid default null,
  p_priority text default 'routine',
  p_priority_reason text default null
)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
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
    raise exception 'Invalid appointment source' using errcode = 'QC001';
  end if;
  if p_priority not in ('emergency', 'urgent', 'routine') then
    raise exception 'Invalid priority' using errcode = 'QC001';
  end if;
  if p_priority <> 'routine' and char_length(btrim(coalesce(p_priority_reason, ''))) < 3 then
    raise exception 'Give a short reason for the urgent or emergency priority' using errcode = 'QC001';
  end if;
  select department_id into v_department_id
  from public.hq_profiles where id = p_doctor_id and role = 'doctor' and is_active = true;
  if v_department_id is null then raise exception 'Doctor is unavailable' using errcode = 'QC001'; end if;

  select coalesce(r.slot_duration_minutes, 15), coalesce(r.max_patients_per_day, 40), coalesce(r.allow_walk_ins, true)
  into v_slot_minutes, v_max_patients, v_allow_walk_ins
  from (select 1) as defaults left join public.hq_queue_rules as r on r.department_id = v_department_id;
  if p_source = 'walk_in' and not v_allow_walk_ins and p_priority <> 'emergency' then
    raise exception 'Walk-ins are disabled for this department' using errcode = 'QC001';
  end if;

  select count(*) into v_active_count from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_appointment_date and status not in ('cancelled', 'no_show');
  -- An emergency is never turned away because the day's quota is used up.
  if v_active_count >= v_max_patients and p_priority <> 'emergency' then
    raise exception 'The queue is full for this day' using errcode = 'QC001';
  end if;

  if p_source = 'appointment' then
    select exists(select 1 from public.hq_doctor_availability where doctor_id = p_doctor_id) into v_has_schedule;
    if v_has_schedule then
      select exists(
        select 1 from public.hq_doctor_availability
        where doctor_id = p_doctor_id
          and weekday = (extract(isodow from p_appointment_date)::smallint - 1)
          and is_break = false
          and p_start_time >= start_time
          and p_start_time + make_interval(mins => v_slot_minutes) <= end_time
      ) into v_scheduled;
      if not v_scheduled then raise exception 'The selected time is outside the doctor schedule' using errcode = 'QC001'; end if;
    end if;
  end if;

  if p_patient_id is not null then
    select full_name, phone into v_name, v_phone
    from public.hq_profiles where id = p_patient_id and role = 'patient' and is_active = true;
    if not found then raise exception 'Patient is unavailable' using errcode = 'QC001'; end if;
    if p_dependent_id is not null then
      select full_name into v_name from public.hq_dependents
      where id = p_dependent_id and guardian_id = p_patient_id and is_active;
      if not found then raise exception 'Family member not found' using errcode = 'QC001'; end if;
    end if;
    if exists (
      select 1 from public.hq_appointments
      where patient_id = p_patient_id and doctor_id = p_doctor_id and appointment_date = p_appointment_date
        and dependent_id is not distinct from p_dependent_id
        and status in ('booked', 'checked_in', 'called', 'in_progress', 'skipped')
    ) then
      raise exception 'There is already an active appointment with this doctor on that date' using errcode = 'QC001';
    end if;
  end if;
  v_name := coalesce(nullif(trim(p_patient_name), ''), v_name, 'Walk-in patient');
  v_phone := coalesce(nullif(trim(p_patient_phone), ''), v_phone);
  v_status := case when p_source = 'walk_in' then 'checked_in' else 'booked' end;

  perform pg_advisory_xact_lock(hashtextextended(p_doctor_id::text || p_appointment_date::text, 0));
  select coalesce(max(queue_number), 0) + 1 into v_queue_number
  from public.hq_appointments where doctor_id = p_doctor_id and appointment_date = p_appointment_date;

  insert into public.hq_appointments (
    patient_id, patient_name, patient_phone, doctor_id, department_id, appointment_date, start_time,
    queue_number, queue_sort, source, status, created_by, dependent_id,
    priority, priority_reason, priority_set_by, checked_in_at
  ) values (
    p_patient_id, v_name, v_phone, p_doctor_id, v_department_id, p_appointment_date, p_start_time,
    v_queue_number, v_queue_number, p_source, v_status, p_created_by, p_dependent_id,
    p_priority, case when p_priority = 'routine' then null else btrim(p_priority_reason) end,
    case when p_priority = 'routine' then null else p_created_by end,
    case when v_status = 'checked_in' then now() else null end
  ) returning * into v_appointment;

  insert into public.hq_queue_events (appointment_id, actor_id, event_type)
  values (v_appointment.id, p_created_by, case when p_source = 'walk_in' then 'walk_in_created' else 'booked' end);
  return v_appointment;
end $$;

drop function if exists public.hq_reschedule_appointment(uuid, uuid, date, time, uuid);
create or replace function public.hq_reschedule_appointment(
  p_appointment_id uuid, p_doctor_id uuid, p_appointment_date date, p_start_time time, p_actor_id uuid
)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_old public.hq_appointments; v_new public.hq_appointments;
begin
  select * into v_old from public.hq_appointments where id = p_appointment_id for update;
  if not found or v_old.status not in ('booked', 'checked_in') then
    raise exception 'This appointment can no longer be rescheduled' using errcode = 'QC001';
  end if;
  update public.hq_appointments set status = 'cancelled', updated_at = now() where id = p_appointment_id;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type)
  values (p_appointment_id, p_actor_id, 'rescheduled');
  v_new := public.hq_book_appointment(
    v_old.patient_id, p_doctor_id, p_appointment_date, p_start_time, v_old.source,
    v_old.patient_name, v_old.patient_phone, p_actor_id, v_old.dependent_id,
    v_old.priority, v_old.priority_reason
  );
  if v_old.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_old.patient_id, 'Appointment rescheduled', 'Your appointment time has been updated.', 'info');
  end if;
  return v_new;
end $$;

-- Check-in with late-arrival rule: a booked patient who arrives more than the
-- department's "late after" minutes past their slot rejoins at the back of the
-- line (their token number does not change).
create or replace function public.hq_check_in(p_appointment_id uuid, p_actor_id uuid, p_local_now timestamp)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  v_appt public.hq_appointments;
  v_late_after integer := 15;
  v_slot_start timestamp;
  v_late boolean := false;
begin
  select * into v_appt from public.hq_appointments where id = p_appointment_id for update;
  if not found or v_appt.status <> 'booked' then
    raise exception 'This booking cannot be checked in' using errcode = 'QC001';
  end if;
  select coalesce(r.late_after_minutes, 15) into v_late_after
  from (select 1) d left join public.hq_queue_rules r on r.department_id = v_appt.department_id;
  v_slot_start := v_appt.appointment_date + v_appt.start_time;
  v_late := v_appt.source = 'appointment' and p_local_now > v_slot_start + make_interval(mins => v_late_after);

  perform pg_advisory_xact_lock(hashtextextended(v_appt.doctor_id::text || v_appt.appointment_date::text, 0));
  update public.hq_appointments
  set status = 'checked_in', checked_in_at = now(), updated_at = now(), is_late = v_late,
      queue_sort = case when v_late then (select coalesce(max(queue_sort), 0) + 1 from public.hq_appointments
                                          where doctor_id = v_appt.doctor_id and appointment_date = v_appt.appointment_date)
                        else queue_sort end
  where id = p_appointment_id returning * into v_appt;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type, details)
  values (p_appointment_id, p_actor_id, 'checked_in', jsonb_build_object('late', v_late));
  if v_late then
    insert into public.hq_queue_events (appointment_id, actor_id, event_type)
    values (p_appointment_id, p_actor_id, 'late_requeued');
  end if;
  return v_appt;
end $$;

-- Atomic "Call next": one advisory lock per doctor/day plus SKIP LOCKED means two
-- clicks or two devices can never call two patients or the same patient twice.
-- Order: emergency, then urgent, then routine; inside a priority by queue position.
drop function if exists public.hq_call_next_patient(uuid, uuid, date);
create or replace function public.hq_call_next_patient(p_doctor_id uuid, p_actor_id uuid, p_queue_date date)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_next public.hq_appointments; v_busy integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('call:' || p_doctor_id::text || p_queue_date::text, 0));
  select count(*) into v_busy from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_queue_date and status in ('called', 'in_progress');
  if v_busy > 0 then
    raise exception 'Finish, skip or mark the current patient before calling the next one' using errcode = 'QC001';
  end if;
  select * into v_next from public.hq_appointments
  where doctor_id = p_doctor_id and appointment_date = p_queue_date and status = 'checked_in'
  order by public.hq_priority_rank(priority), queue_sort, queue_number
  for update skip locked limit 1;
  if not found then return null; end if;
  update public.hq_appointments set status = 'called', called_at = now(), updated_at = now()
  where id = v_next.id returning * into v_next;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type) values (v_next.id, p_actor_id, 'called');
  if v_next.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_next.patient_id, 'It is your turn', 'Please go to your consultation room now.', 'success');
  end if;
  return v_next;
end $$;

create or replace function public.hq_start_consultation(p_appointment_id uuid, p_doctor_id uuid)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_appt public.hq_appointments;
begin
  update public.hq_appointments set status = 'in_progress', started_at = now(), updated_at = now()
  where id = p_appointment_id and doctor_id = p_doctor_id and status = 'called'
  returning * into v_appt;
  if not found then raise exception 'Call the patient before starting the consultation' using errcode = 'QC001'; end if;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type) values (p_appointment_id, p_doctor_id, 'started');
  return v_appt;
end $$;

create or replace function public.hq_skip_patient(p_appointment_id uuid, p_actor_id uuid)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_appt public.hq_appointments;
begin
  update public.hq_appointments set status = 'skipped', skipped_at = now(), updated_at = now()
  where id = p_appointment_id and status in ('called', 'checked_in') returning * into v_appt;
  if not found then raise exception 'This patient cannot be skipped right now' using errcode = 'QC001'; end if;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type) values (p_appointment_id, p_actor_id, 'skipped');
  if v_appt.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_appt.patient_id, 'You were skipped for now',
            'You were not at the room when called. Tell reception or tap "I am here" in the app to rejoin the queue.', 'warning');
  end if;
  return v_appt;
end $$;

create or replace function public.hq_recall_patient(p_appointment_id uuid, p_actor_id uuid)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_appt public.hq_appointments;
begin
  select * into v_appt from public.hq_appointments where id = p_appointment_id for update;
  if not found or v_appt.status <> 'skipped' then
    raise exception 'Only a skipped patient can be recalled' using errcode = 'QC001';
  end if;
  if v_appt.recall_count >= 2 then
    raise exception 'This patient was already recalled twice. Mark a no-show or rebook.' using errcode = 'QC001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_appt.doctor_id::text || v_appt.appointment_date::text, 0));
  update public.hq_appointments
  set status = 'checked_in', recall_count = recall_count + 1, skipped_at = null, updated_at = now(),
      queue_sort = (select coalesce(max(queue_sort), 0) + 1 from public.hq_appointments
                    where doctor_id = v_appt.doctor_id and appointment_date = v_appt.appointment_date)
  where id = p_appointment_id returning * into v_appt;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type) values (p_appointment_id, p_actor_id, 'recalled');
  return v_appt;
end $$;

-- Referral / handoff: the appointment moves to the other doctor's queue and, because
-- every clinical read is scoped to the assigned doctor, access moves with it.
create or replace function public.hq_refer_appointment(
  p_appointment_id uuid, p_from_doctor uuid, p_to_doctor uuid, p_reason text, p_actor_id uuid
)
returns public.hq_appointments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_appt public.hq_appointments; v_dept uuid; v_q integer;
begin
  if p_from_doctor = p_to_doctor then raise exception 'Choose a different doctor' using errcode = 'QC001'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give a reason for the referral' using errcode = 'QC001'; end if;
  select department_id into v_dept from public.hq_profiles where id = p_to_doctor and role = 'doctor' and is_active;
  if v_dept is null then raise exception 'The receiving doctor is unavailable' using errcode = 'QC001'; end if;
  select * into v_appt from public.hq_appointments where id = p_appointment_id for update;
  if not found or v_appt.doctor_id <> p_from_doctor or v_appt.status not in ('checked_in', 'called', 'in_progress', 'skipped') then
    raise exception 'This patient cannot be referred right now' using errcode = 'QC001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_to_doctor::text || v_appt.appointment_date::text, 0));
  select coalesce(max(queue_number), 0) + 1 into v_q from public.hq_appointments
  where doctor_id = p_to_doctor and appointment_date = v_appt.appointment_date;
  update public.hq_appointments
  set doctor_id = p_to_doctor, department_id = v_dept, queue_number = v_q, queue_sort = v_q,
      status = 'checked_in', referred_from_doctor_id = p_from_doctor,
      called_at = null, started_at = null, skipped_at = null, updated_at = now()
  where id = p_appointment_id returning * into v_appt;
  insert into public.hq_queue_events (appointment_id, actor_id, event_type, details)
  values (p_appointment_id, p_actor_id, 'referred', jsonb_build_object('from', p_from_doctor, 'to', p_to_doctor, 'reason', btrim(p_reason)));
  if v_appt.patient_id is not null then
    insert into public.hq_notifications (recipient_id, title, message, category)
    values (v_appt.patient_id, 'You have been referred', 'Your doctor referred you. Your new token is A-' || v_q || '.', 'info');
  end if;
  return v_appt;
end $$;

-- ------------------------------------------------------- RLS and grants ----
do $$
declare t text;
begin
  foreach t in array array[
    'hq_dependents','hq_audit_log','hq_consents','hq_triage_vitals','hq_consultations',
    'hq_prescriptions','hq_followups','hq_identity_photos','hq_identity_photo_unlocks',
    'hq_break_glass','hq_sms_outbox','hq_queue_alerts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- The audit log can be inserted into and read, never changed or removed.
revoke update, delete, truncate on public.hq_audit_log from service_role, anon, authenticated, public;
grant select, insert on public.hq_audit_log to service_role;
grant usage, select on all sequences in schema public to service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'hq_book_appointment(uuid,uuid,date,time,text,text,text,uuid,uuid,text,text)',
    'hq_reschedule_appointment(uuid,uuid,date,time,uuid)',
    'hq_check_in(uuid,uuid,timestamp)',
    'hq_call_next_patient(uuid,uuid,date)',
    'hq_start_consultation(uuid,uuid)',
    'hq_skip_patient(uuid,uuid)',
    'hq_recall_patient(uuid,uuid)',
    'hq_refer_appointment(uuid,uuid,uuid,text,uuid)',
    'hq_break_glass_open(uuid,uuid,text,integer)',
    'hq_has_break_glass(uuid,uuid)',
    'hq_unlock_identity_photo(uuid,uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

insert into public.hq_queue_rules (department_id)
select id from public.hq_departments on conflict (department_id) do nothing;

commit;
