# ระบบเช็กชื่อและจัดลำดับ (FIFO) — Supabase + GitHub + Vercel

## ติดตั้ง
1. **Supabase**: สร้างโปรเจกต์ → SQL Editor → วาง `schema.sql` ทั้งไฟล์แล้ว Run
2. **ผู้ดูแล**: Authentication → Users → Add user (อีเมล+รหัสผ่าน) แล้วรัน
   `insert into public.admin_users (user_id) select id from auth.users where email = 'อีเมลแอดมิน';`
   และไปที่ Authentication → Sign In / Providers ปิด "Allow new users to sign up"
3. **config.js**: ใส่ Project URL และ anon public key (Project Settings → API) — ห้ามใส่ service_role
4. **GitHub**: push โฟลเดอร์นี้ขึ้น repo
5. **Vercel**: Import repo → Framework: Other (ไม่ต้อง build) → Deploy

## ใช้งาน
- เข้า `/admin` → สร้างรอบ (วางรายชื่อบรรทัดละคน) → เปลี่ยนสถานะเป็น "เปิดรับ"
- คัดลอก "ลิงก์สำหรับส่งในกลุ่ม LINE" แล้วส่งเอง
- ปลดล็อกสิทธิ์ต้องใส่เหตุผล ทุกการทำงานลง Audit Log
