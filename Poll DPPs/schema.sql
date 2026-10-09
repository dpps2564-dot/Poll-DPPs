-- =====================================================================
-- ระบบเช็กชื่อและจัดลำดับ FIFO (LINE link → Web App)  |  Supabase / Postgres
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทั้งไฟล์แล้วกด Run
-- =====================================================================

-- ---------- 1) ตาราง ----------
create table public.rounds (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  description text,
  capacity    int  not null default 50 check (capacity > 0),
  status      text not null default 'draft' check (status in ('draft','open','closed')),
  seq_counter int  not null default 0,          -- ตัวนับลำดับ เพิ่มทางเดียว ไม่ถูกใช้ซ้ำ
  created_at  timestamptz not null default now()
);

create table public.participants (
  id         uuid primary key default gen_random_uuid(),
  round_id   uuid not null references public.rounds(id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  sequence   int,                                -- null = ยังไม่มีผู้เลือก
  claimed_at timestamptz,                        -- เวลาจาก server (ms precision)
  created_at timestamptz not null default now(),
  unique (round_id, sequence)
);
create index participants_round_seq_idx on public.participants (round_id, sequence);

-- เก็บ device ของคนที่กด (ผู้ใช้ทั่วไปอ่านไม่ได้) → กัน 1 เครื่องเลือกหลายชื่อ
create table public.claim_devices (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  round_id       uuid not null references public.rounds(id) on delete cascade,
  device_id      text not null,
  unique (round_id, device_id)
);

-- Audit log: เพิ่มได้อย่างเดียว (ไม่มี update/delete)
create table public.audit_logs (
  id         bigint generated always as identity primary key,
  round_id   uuid,                               -- ไม่ใส่ FK เพื่อให้ log อยู่ต่อแม้ลบรอบ
  actor      text not null,
  action     text not null,
  details    text,
  created_at timestamptz not null default now()
);

create table public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ---------- 2) ฟังก์ชันช่วย ----------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

-- ---------- 3) ฟังก์ชันจองลำดับแบบ atomic ----------
-- ล็อกแถวของ round (FOR UPDATE) ทำให้ทุกคำขอในรอบเดียวกันเข้าคิวทีละคน
-- → เช็กความจุ/ชื่อซ้ำ/คนซ้ำ + ออกเลขลำดับ + บันทึกเวลา ใน transaction เดียว
create or replace function public.claim_participant(p_participant_id uuid, p_device_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_round_id uuid;
  v_round    public.rounds%rowtype;
  v_p        public.participants%rowtype;
  v_mine     public.participants%rowtype;
  v_taken    int;
  v_seq      int;
  v_now      timestamptz;
begin
  if p_device_id is null or length(p_device_id) < 16 then
    return jsonb_build_object('ok', false, 'code', 'BAD_DEVICE',
      'message', 'ไม่พบรหัสอุปกรณ์ กรุณารีเฟรชหน้าแล้วลองใหม่');
  end if;

  select round_id into v_round_id from public.participants where id = p_participant_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายชื่อนี้ในระบบ');
  end if;

  -- ล็อกรอบ แล้วค่อยอ่านข้อมูลที่ใช้ตัดสิน
  select * into v_round from public.rounds where id = v_round_id for update;
  select * into v_p from public.participants where id = p_participant_id;

  if v_round.status <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'CLOSED', 'message', 'ปิดรับการยืนยันแล้ว');
  end if;

  select p.* into v_mine
  from public.participants p
  join public.claim_devices d on d.participant_id = p.id
  where d.round_id = v_round.id and d.device_id = p_device_id;
  if found then
    return jsonb_build_object('ok', false, 'code', 'USER_ALREADY_CLAIMED',
      'message', 'คุณยืนยันชื่อ "' || v_mine.name || '" ไปแล้ว (ลำดับที่ ' || v_mine.sequence || ')',
      'sequence', v_mine.sequence);
  end if;

  if v_p.sequence is not null then
    return jsonb_build_object('ok', false, 'code', 'NAME_TAKEN',
      'message', 'ชื่อ "' || v_p.name || '" ถูกเลือกไปแล้ว');
  end if;

  select count(*) into v_taken from public.participants
  where round_id = v_round.id and sequence is not null;
  if v_taken >= v_round.capacity then
    return jsonb_build_object('ok', false, 'code', 'CAPACITY_FULL',
      'message', 'สิทธิ์ครบ ' || v_round.capacity || ' คนแล้ว');
  end if;

  v_seq := v_round.seq_counter + 1;
  v_now := clock_timestamp();

  update public.rounds set seq_counter = v_seq where id = v_round.id;
  update public.participants set sequence = v_seq, claimed_at = v_now where id = v_p.id;
  insert into public.claim_devices (participant_id, round_id, device_id)
  values (v_p.id, v_round.id, p_device_id);

  insert into public.audit_logs (round_id, actor, action, details)
  values (v_round.id, 'ผู้ใช้', 'ยืนยันรายชื่อ',
          'เลือกชื่อ "' || v_p.name || '" ได้ลำดับ #' || v_seq ||
          ' เวลา ' || to_char(v_now at time zone 'Asia/Bangkok', 'HH24:MI:SS.MS'));

  return jsonb_build_object('ok', true, 'sequence', v_seq,
                            'name', v_p.name, 'claimed_at', v_now);
end;
$$;

-- ---------- 4) Admin: ปลดล็อกสิทธิ์ (ต้องระบุเหตุผล) ----------
create or replace function public.admin_unlock_participant(p_participant_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.participants%rowtype;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    return jsonb_build_object('ok', false, 'message', 'กรุณาระบุเหตุผล');
  end if;

  select * into v_p from public.participants where id = p_participant_id for update;
  if not found or v_p.sequence is null then
    return jsonb_build_object('ok', false, 'message', 'ชื่อนี้ไม่ได้ถูกเลือกอยู่');
  end if;

  update public.participants set sequence = null, claimed_at = null where id = v_p.id;
  delete from public.claim_devices where participant_id = v_p.id;

  insert into public.audit_logs (round_id, actor, action, details)
  values (v_p.round_id, coalesce(auth.jwt() ->> 'email', 'Admin'), 'ปลดล็อกสิทธิ์',
          'ปลดล็อก "' || v_p.name || '" (ยกเลิกลำดับ #' || v_p.sequence || ') เหตุผล: ' || p_reason);

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- 5) Trigger บันทึก Audit เมื่อ Admin แก้ข้อมูล ----------
create or replace function public.trg_audit_admin()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor text := coalesce(auth.jwt() ->> 'email', 'Admin');
begin
  if tg_table_name = 'rounds' then
    if tg_op = 'INSERT' then
      insert into audit_logs (round_id, actor, action, details)
      values (new.id, v_actor, 'สร้างรอบ', new.title || ' (ความจุ ' || new.capacity || ' คน)');
    elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
      insert into audit_logs (round_id, actor, action, details)
      values (new.id, v_actor, 'เปลี่ยนสถานะรอบ', old.status || ' → ' || new.status);
    end if;
  elsif tg_table_name = 'participants' then
    if tg_op = 'INSERT' then
      insert into audit_logs (round_id, actor, action, details)
      values (new.round_id, v_actor, 'เพิ่มรายชื่อ', new.name);
    elsif tg_op = 'DELETE' then
      insert into audit_logs (round_id, actor, action, details)
      values (old.round_id, v_actor, 'ลบรายชื่อ', old.name);
    end if;
  end if;
  return null;
end;
$$;

create trigger audit_rounds
  after insert or update on public.rounds
  for each row execute function public.trg_audit_admin();

create trigger audit_participants
  after insert or delete on public.participants
  for each row execute function public.trg_audit_admin();

-- ---------- 6) Row Level Security ----------
alter table public.rounds        enable row level security;
alter table public.participants  enable row level security;
alter table public.claim_devices enable row level security;
alter table public.audit_logs    enable row level security;
alter table public.admin_users   enable row level security;

-- rounds: ทุกคนอ่านได้เฉพาะรอบที่ไม่ใช่ draft / admin ทำได้ทุกอย่าง
create policy rounds_read on public.rounds for select
  using (status in ('open','closed') or public.is_admin());
create policy rounds_admin_write on public.rounds for all
  using (public.is_admin()) with check (public.is_admin());

-- participants: อ่านได้ตามสถานะรอบ / ผู้ใช้ทั่วไปแก้ตรงๆ ไม่ได้ (ต้องผ่าน claim_participant เท่านั้น)
create policy participants_read on public.participants for select
  using (exists (select 1 from public.rounds r
                 where r.id = round_id and (r.status in ('open','closed') or public.is_admin())));
create policy participants_admin_insert on public.participants for insert
  with check (public.is_admin());
create policy participants_admin_update on public.participants for update
  using (public.is_admin()) with check (public.is_admin());
create policy participants_admin_delete on public.participants for delete
  using (public.is_admin() and sequence is null);   -- ลบชื่อที่มีลำดับแล้วไม่ได้ ต้องปลดล็อกก่อน

-- audit_logs: เฉพาะ admin อ่านได้ / ไม่มีใครแก้หรือลบได้
create policy audit_admin_read on public.audit_logs for select
  using (public.is_admin());
revoke insert, update, delete on public.audit_logs from anon, authenticated;

-- claim_devices / admin_users: ไม่เปิดให้ client เข้าถึงเลย
revoke all on public.claim_devices from anon, authenticated;
revoke all on public.admin_users   from anon, authenticated;

-- ---------- 7) สิทธิ์เรียกฟังก์ชัน ----------
revoke execute on function public.claim_participant(uuid, text)          from public;
revoke execute on function public.admin_unlock_participant(uuid, text)   from public;
grant  execute on function public.claim_participant(uuid, text)          to anon, authenticated;
grant  execute on function public.admin_unlock_participant(uuid, text)   to authenticated;
grant  execute on function public.is_admin()                             to anon, authenticated;

-- ---------- 8) Realtime ----------
alter publication supabase_realtime add table public.participants;
alter publication supabase_realtime add table public.rounds;

-- ---------- 9) ตั้งค่า Admin (ทำครั้งเดียวหลังรันไฟล์นี้) ----------
-- 1. Authentication → Users → Add user (อีเมล + รหัสผ่านของแอดมิน)
-- 2. แล้วรันคำสั่งนี้ (แก้อีเมลให้ตรง):
--    insert into public.admin_users (user_id)
--    select id from auth.users where email = 'admin@dpps.local';
