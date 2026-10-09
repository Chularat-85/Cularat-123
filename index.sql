-- ============================================================================
-- setup.sql : ระบบฐานข้อมูล CAI เทคโนโลยี ม.1 สำหรับ Supabase (เวอร์ชันสมบูรณ์)
-- อิงตามแนวทาง สสวท. (วิทยาการคำนวณ และ การออกแบบและเทคโนโลยี)
-- ============================================================================

-- 1. กำหนด Extension ที่จำเป็น
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. สร้างตารางหลักของระบบ
-- 2.1 ตารางสิทธิ์ครูผู้สอน
CREATE TABLE IF NOT EXISTS public.teachers (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- 2.2 ตารางข้อมูลนักเรียนที่ลงทะเบียนล่วงหน้า
CREATE TABLE IF NOT EXISTS public.students (
    id VARCHAR(11) PRIMARY KEY, -- รหัสนักเรียน 11 หลัก เช่น 67010100001
    title TEXT NOT NULL,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    section TEXT NOT NULL,
    user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    photo_path TEXT,
    created_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- 2.3 ตารางบันทึกการทำแบบทดสอบ (pre / post)
CREATE TABLE IF NOT EXISTS public.attempts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('pre', 'post')),
    test_set TEXT NOT NULL CHECK (test_set IN ('A', 'B')),
    score INTEGER NOT NULL CHECK (score >= 0 AND score <= 10),
    answers JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    CONSTRAINT unique_user_kind UNIQUE (user_id, kind)
);

-- 2.4 ตารางความก้าวหน้ารายหน่วย (1-5)
CREATE TABLE IF NOT EXISTS public.progress (
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    unit INTEGER NOT NULL CHECK (unit BETWEEN 1 AND 5),
    done BOOLEAN NOT NULL DEFAULT true,
    completed_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    PRIMARY KEY (user_id, unit)
);

-- 2.5 ตารางส่งงานและการประเมิน
CREATE TABLE IF NOT EXISTS public.submissions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    unit INTEGER NOT NULL CHECK (unit BETWEEN 1 AND 5),
    kind TEXT NOT NULL CHECK (kind IN ('link', 'file')),
    url TEXT CHECK (url IS NULL OR url ~* '^https?://'),
    storage_path TEXT,
    note TEXT,
    score NUMERIC(4, 1) CHECK (score IS NULL OR (score >= 0 AND score <= 100)),
    teacher_comment TEXT,
    created_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    -- ผูก Foreign Key กับ students(user_id) เพื่อให้ PostgREST embed relation ได้อย่างสมบูรณ์
    CONSTRAINT fk_submissions_students FOREIGN KEY (user_id) REFERENCES public.students(user_id) ON DELETE CASCADE
);

-- 2.6 ตารางเอกสารและสื่อการเรียนรู้
CREATE TABLE IF NOT EXISTS public.materials (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('link', 'file')),
    url TEXT CHECK (url IS NULL OR url ~* '^https?://'),
    storage_path TEXT,
    file_name TEXT,
    created_at TIMESTAMPTZ DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- 3. ฟังก์ชันและ Trigger ปลอดภัย
-- 3.1 ฟังก์ชันตรวจสอบสิทธิ์ครูผู้สอน (SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.is_teacher()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 
        FROM public.teachers 
        WHERE user_id = auth.uid()
    );
$$;

-- 3.2 ฟังก์ชันผูกบัญชีนักเรียนเมื่อสมัครสมาชิกใหม่ (auth.users Trigger)
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_email TEXT;
    v_student_id TEXT;
    v_existing_user UUID;
BEGIN
    v_email := LOWER(COALESCE(NEW.email, ''));
    
    -- ตรวจสอบว่าเป็นรูปแบบอีเมลรหัสนักเรียน 11 หลัก เช่น 67010100001@school.ac.th
    IF v_email ~ '^[0-9]{11}@' THEN
        v_student_id := SUBSTRING(v_email FROM '^([0-9]{11})@');
        
        -- ตรวจสอบว่ามีรหัสในรายชื่อและยังไม่เคยผูกบัญชี
        SELECT user_id INTO v_existing_user
        FROM public.students
        WHERE id = v_student_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'ไม่พบรหัสนักเรียน % ในฐานข้อมูล กรุณาติดต่อครูผู้สอน', v_student_id;
        ELSIF v_existing_user IS NOT NULL AND v_existing_user <> NEW.id THEN
            RAISE EXCEPTION 'รหัสนักเรียน % ถูกลงทะเบียนใช้งานไปแล้ว', v_student_id;
        ELSE
            -- ผูก user_id เข้ากับตาราง students
            UPDATE public.students
            SET user_id = NEW.id
            WHERE id = v_student_id;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- 3.3 Trigger ตรวจสอบการแก้ไขข้อมูลตาราง students (นักเรียนแก้ได้เฉพาะ photo_path)
CREATE OR REPLACE FUNCTION public.check_student_update_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
BEGIN
    IF NOT public.is_teacher() THEN
        IF NEW.id <> OLD.id 
           OR NEW.title <> OLD.title 
           OR NEW.first_name <> OLD.first_name 
           OR NEW.last_name <> OLD.last_name 
           OR NEW.section <> OLD.section 
           OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
            RAISE EXCEPTION 'นักเรียนสามารถแก้ไขได้เฉพาะรูปโปรไฟล์เท่านั้น';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_guard_students_update ON public.students;
CREATE TRIGGER tr_guard_students_update
    BEFORE UPDATE ON public.students
    FOR EACH ROW EXECUTE FUNCTION public.check_student_update_guard();

-- 3.4 Trigger ตรวจสอบการแก้ไขข้อมูลตาราง submissions (นักเรียนแก้คะแนนหรือคอมเมนต์ไม่ได้)
CREATE OR REPLACE FUNCTION public.check_submission_update_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
BEGIN
    IF NOT public.is_teacher() THEN
        IF NEW.score IS DISTINCT FROM OLD.score OR NEW.teacher_comment IS DISTINCT FROM OLD.teacher_comment THEN
            RAISE EXCEPTION 'นักเรียนไม่สามารถแก้ไขคะแนนหรือข้อเสนอแนะของครูได้';
        END IF;
        IF NEW.user_id <> OLD.user_id THEN
            RAISE EXCEPTION 'ไม่อนุญาตให้แก้ไขเจ้าของงาน';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_guard_submissions_update ON public.submissions;
CREATE TRIGGER tr_guard_submissions_update
    BEFORE UPDATE ON public.submissions
    FOR EACH ROW EXECUTE FUNCTION public.check_submission_update_guard();

-- 3.5 RPC คำนวณและบันทึกคะแนนสอบอย่างปลอดภัยทางเซิร์ฟเวอร์
CREATE OR REPLACE FUNCTION public.submit_exam_secure(
    p_kind TEXT,
    p_test_set TEXT,
    p_answers JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_score INTEGER := 0;
    v_ans_key JSONB;
    v_q_key TEXT;
    v_student_ans TEXT;
    v_correct_ans TEXT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'กรุณาเข้าสู่ระบบก่อนทำแบบทดสอบ';
    END IF;

    IF p_kind NOT IN ('pre', 'post') OR p_test_set NOT IN ('A', 'B') THEN
        RAISE EXCEPTION 'พารามิเตอร์แบบทดสอบไม่ถูกต้อง';
    END IF;

    -- ตรวจสอบว่าเคยทำแล้วหรือไม่
    IF EXISTS (SELECT 1 FROM public.attempts WHERE user_id = v_user_id AND kind = p_kind) THEN
        RAISE EXCEPTION 'คุณได้ทำแบบทดสอบชุดนี้ไปแล้ว ไม่สามารถส่งซ้ำได้';
    END IF;

    -- เฉลยมาตรฐาน 10 ข้อ (ข้อ 1-10)
    -- ชุด A: 1:B, 2:C, 3:B, 4:A, 5:B, 6:C, 7:A, 8:B, 9:C, 10:B
    -- ชุด B: 1:B, 2:A, 3:C, 4:B, 5:C, 6:B, 7:A, 8:C, 9:B, 10:B
    IF p_test_set = 'A' THEN
        v_ans_key := '{"1":"B","2":"C","3":"B","4":"A","5":"B","6":"C","7":"A","8":"B","9":"C","10":"B"}'::jsonb;
    ELSE
        v_ans_key := '{"1":"B","2":"A","3":"C","4":"B","5":"C","6":"B","7":"A","8":"C","9":"B","10":"B"}'::jsonb;
    END IF;

    -- ตรวจนับคะแนน
    FOR i IN 1..10 LOOP
        v_q_key := i::text;
        v_student_ans := p_answers->>v_q_key;
        v_correct_ans := v_ans_key->>v_q_key;
        IF v_student_ans IS NOT NULL AND UPPER(v_student_ans) = UPPER(v_correct_ans) THEN
            v_score := v_score + 1;
        END IF;
    END LOOP;

    -- บันทึกคะแนนลง attempts
    INSERT INTO public.attempts(user_id, kind, test_set, score, answers)
    VALUES (v_user_id, p_kind, p_test_set, v_score, p_answers);

    RETURN jsonb_build_object(
        'success', true,
        'kind', p_kind,
        'test_set', p_test_set,
        'score', v_score
    );
END;
$$;

-- 4. วิว results แสดงผลการเรียน (security_invoker = true)
CREATE OR REPLACE VIEW public.results
WITH (security_invoker = true)
AS
SELECT 
    s.id AS student_id,
    s.title,
    s.first_name,
    s.last_name,
    s.section,
    s.user_id,
    s.photo_path,
    pre.score AS pre_score,
    pre.test_set AS pre_set,
    post.score AS post_score,
    post.test_set AS post_set,
    CASE 
        WHEN pre.score IS NOT NULL AND post.score IS NOT NULL THEN
            CASE 
                WHEN pre.score = 10 THEN NULL -- กรณีคะแนนก่อนเรียนเต็ม ให้คำนวณไม่ได้ตามสูตร
                ELSE ROUND(((post.score - pre.score)::NUMERIC / (10 - pre.score)::NUMERIC), 2)
            END
        ELSE NULL
    END AS normalized_gain,
    COALESCE(prog.completed_units, 0) AS completed_units,
    COALESCE(sub.submission_count, 0) AS submission_count
FROM public.students s
LEFT JOIN public.attempts pre ON s.user_id = pre.user_id AND pre.kind = 'pre'
LEFT JOIN public.attempts post ON s.user_id = post.user_id AND post.kind = 'post'
LEFT JOIN (
    SELECT user_id, COUNT(*) AS completed_units
    FROM public.progress
    WHERE done = true
    GROUP BY user_id
) prog ON s.user_id = prog.user_id
LEFT JOIN (
    SELECT user_id, COUNT(*) AS submission_count
    FROM public.submissions
    GROUP BY user_id
) sub ON s.user_id = sub.user_id;

-- 5. การเปิดใช้งานและตั้งค่า Row Level Security (RLS)
ALTER TABLE public.teachers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;

-- เพิกถอนสิทธิ์เกินจำเป็นจาก anon และมอบสิทธิ์ที่จำเป็นแก่ authenticated
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.students TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.progress TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attempts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.materials TO authenticated;
GRANT SELECT ON public.teachers TO authenticated;
GRANT SELECT ON public.results TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_exam_secure(TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_teacher() TO authenticated;

-- นโยบายตาราง teachers
CREATE POLICY "teachers_read_self"
    ON public.teachers FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- นโยบายตาราง students
CREATE POLICY "students_read_policy"
    ON public.students FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_teacher());

CREATE POLICY "students_update_photo_only"
    ON public.students FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "teachers_manage_students"
    ON public.students FOR ALL
    TO authenticated
    USING (public.is_teacher())
    WITH CHECK (public.is_teacher());

-- นโยบายตาราง attempts
CREATE POLICY "attempts_read_policy"
    ON public.attempts FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_teacher());

-- นโยบายตาราง progress
CREATE POLICY "progress_read_policy"
    ON public.progress FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_teacher());

CREATE POLICY "progress_insert_own"
    ON public.progress FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "progress_update_own"
    ON public.progress FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- นโยบายตาราง submissions
CREATE POLICY "submissions_read_policy"
    ON public.submissions FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_teacher());

CREATE POLICY "submissions_insert_own"
    ON public.submissions FOR INSERT
    TO authenticated
    WITH CHECK (
        user_id = auth.uid() 
        AND score IS NULL 
        AND teacher_comment IS NULL
    );

CREATE POLICY "submissions_update_student"
    ON public.submissions FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "submissions_update_teacher"
    ON public.submissions FOR UPDATE
    TO authenticated
    USING (public.is_teacher())
    WITH CHECK (public.is_teacher());

CREATE POLICY "submissions_delete_teacher"
    ON public.submissions FOR DELETE
    TO authenticated
    USING (public.is_teacher());

-- นโยบายตาราง materials
CREATE POLICY "materials_read_all_authenticated"
    ON public.materials FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "materials_manage_teacher"
    ON public.materials FOR ALL
    TO authenticated
    USING (public.is_teacher())
    WITH CHECK (public.is_teacher());

-- 6. การตั้งค่า Storage Buckets แบบ Private และนโยบาย
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES 
    ('photos', 'photos', false, 2097152, ARRAY['image/jpeg', 'image/png']),
    ('submissions', 'submissions', false, 20971520, ARRAY['image/jpeg', 'image/png', 'application/pdf', 'video/mp4']),
    ('materials', 'materials', false, 52428800, ARRAY['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'])
ON CONFLICT (id) DO UPDATE SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- RLS ของ storage.objects
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- นโยบาย Bucket: photos
CREATE POLICY "photos_select_policy"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'photos' 
        AND (
            (storage.foldername(name))[1] = auth.uid()::text 
            OR public.is_teacher()
        )
    );

CREATE POLICY "photos_insert_policy"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'photos' 
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "photos_update_policy"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
        bucket_id = 'photos' 
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "photos_delete_policy"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (
        bucket_id = 'photos' 
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

-- นโยบาย Bucket: submissions
CREATE POLICY "submissions_select_policy"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'submissions' 
        AND (
            (storage.foldername(name))[1] = auth.uid()::text 
            OR public.is_teacher()
        )
    );

CREATE POLICY "submissions_insert_policy"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'submissions' 
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "submissions_update_policy"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
        bucket_id = 'submissions' 
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

-- นโยบาย Bucket: materials
CREATE POLICY "materials_select_policy"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (bucket_id = 'materials');

CREATE POLICY "materials_insert_policy"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (bucket_id = 'materials' AND public.is_teacher());

CREATE POLICY "materials_delete_policy"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (bucket_id = 'materials' AND public.is_teacher());

-- 7. ข้อมูลจำลองรายชื่อนักเรียน 6 แถว (สำหรับการทดสอบระบบ)
INSERT INTO public.students (id, title, first_name, last_name, section)
VALUES 
    ('67010100001', 'เด็กชาย', 'กิตติศักดิ์', 'เจริญผล', '1/1'),
    ('67010100002', 'เด็กหญิง', 'ขวัญชนก', 'วงศ์สุวรรณ', '1/1'),
    ('67010100003', 'เด็กชาย', 'จิรภัทร', 'สุขสำราญ', '1/1'),
    ('67010100004', 'เด็กหญิง', 'ชลธิชา', 'แสงทอง', '1/2'),
    ('67010100005', 'เด็กชาย', 'ณัฐพงษ์', 'ปรีชากุล', '1/2'),
    ('67010100006', 'เด็กหญิง', 'ธนภรณ์', 'ศิริวัฒน์', '1/2')
ON CONFLICT (id) DO NOTHING;

-- 8. ตัวอย่างคำสั่งมอบสิทธิ์ครูผู้สอน
/*
-- 1. ให้ครูสมัครสมาชิกผ่านหน้าระบบด้วยอีเมลครูจริง เช่น teacher.somchai@school.ac.th
-- 2. นำ User UID จากเมนู Authentication > Users มาใส่ในคำสั่งด้านล่างนี้แล้วกด Run ใน SQL Editor:

INSERT INTO public.teachers (user_id)
VALUES ('00000000-0000-0000-0000-000000000000') -- แทนที่ด้วย UUID ครูจริง
ON CONFLICT (user_id) DO NOTHING;
*/