-- Private patient medical image records, accessed only by the FastAPI service.
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

alter table public.hq_medical_records enable row level security;
revoke all on public.hq_medical_records from anon, authenticated;
grant all on public.hq_medical_records to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('medical-records', 'medical-records', false, 12582912, array['image/jpeg'])
on conflict (id) do update set
  name = excluded.name,
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
