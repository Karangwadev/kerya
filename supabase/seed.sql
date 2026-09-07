-- ============================================================
-- KERYA MAIZE MANAGEMENT SYSTEM — Seed Data
-- ============================================================
--
-- Auth users already created in Dashboard with @kerya.com emails.
-- Run this in: Supabase Dashboard → SQL Editor
--
-- Existing auth users:
--   admin@kerya.com
--   manager@kerya.com
--   staffmain@kerya.com
--   staffrusizi@kerya.com
--   boss1@kerya.com
--   boss2@kerya.com
--   boss3@kerya.com
--
-- ============================================================

DO $$
DECLARE
  v_admin_id         UUID;
  v_manager_id       UUID;
  v_staff_main_id    UUID;
  v_staff_rusizi_id  UUID;
  v_boss1_id         UUID;
  v_boss2_id         UUID;
  v_boss3_id         UUID;
BEGIN

  -- Fetch UUIDs from auth.users by email
  SELECT id INTO v_admin_id         FROM auth.users WHERE email = 'admin@kerya.com';
  SELECT id INTO v_manager_id       FROM auth.users WHERE email = 'manager@kerya.com';
  SELECT id INTO v_staff_main_id    FROM auth.users WHERE email = 'staffmain@kerya.com';
  SELECT id INTO v_staff_rusizi_id  FROM auth.users WHERE email = 'staffrusizi@kerya.com';
  SELECT id INTO v_boss1_id         FROM auth.users WHERE email = 'boss1@kerya.com';
  SELECT id INTO v_boss2_id         FROM auth.users WHERE email = 'boss2@kerya.com';
  SELECT id INTO v_boss3_id         FROM auth.users WHERE email = 'boss3@kerya.com';

  -- Validate all 7 were found
  IF v_admin_id        IS NULL THEN RAISE EXCEPTION 'admin@kerya.com not found in auth.users'; END IF;
  IF v_manager_id      IS NULL THEN RAISE EXCEPTION 'manager@kerya.com not found in auth.users'; END IF;
  IF v_staff_main_id   IS NULL THEN RAISE EXCEPTION 'staffmain@kerya.com not found in auth.users'; END IF;
  IF v_staff_rusizi_id IS NULL THEN RAISE EXCEPTION 'staffrusizi@kerya.com not found in auth.users'; END IF;
  IF v_boss1_id        IS NULL THEN RAISE EXCEPTION 'boss1@kerya.com not found in auth.users'; END IF;
  IF v_boss2_id        IS NULL THEN RAISE EXCEPTION 'boss2@kerya.com not found in auth.users'; END IF;
  IF v_boss3_id        IS NULL THEN RAISE EXCEPTION 'boss3@kerya.com not found in auth.users'; END IF;

  -- Insert profiles
  -- username = what the user types at the login screen
  INSERT INTO public.profiles (id, name, username, role, branch, active)
  VALUES
    (v_admin_id,        'Admin User',    'admin',       'admin',       'All',    true),
    (v_manager_id,      'Main Manager',  'manager',     'manager',     'All',    true),
    (v_staff_main_id,   'Staff Main',    'staffmain',   'staff',       'Main',   true),
    (v_staff_rusizi_id, 'Staff Rusizi',  'staffrusizi', 'staff',       'Rusizi', true),
    (v_boss1_id,        'Boss One',      'boss1',       'stakeholder', 'All',    true),
    (v_boss2_id,        'Boss Two',      'boss2',       'stakeholder', 'All',    true),
    (v_boss3_id,        'Boss Three',    'boss3',       'stakeholder', 'All',    true)
  ON CONFLICT (id) DO UPDATE SET
    name     = EXCLUDED.name,
    username = EXCLUDED.username,
    role     = EXCLUDED.role,
    branch   = EXCLUDED.branch,
    active   = EXCLUDED.active;

  RAISE NOTICE 'Seed complete — 7 profiles inserted successfully.';

END $$;

-- Verify with:
-- SELECT username, role, branch, active FROM public.profiles ORDER BY role;
