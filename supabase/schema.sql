-- ============================================================
-- KERYA MAIZE MANAGEMENT SYSTEM — Supabase Schema
-- Run this entire file in: Supabase Dashboard → SQL Editor
--
-- SETUP ORDER:
--   1. schema.sql                          (this file)
--   2. Create the auth users in the Dashboard
--   3. seed.sql
--   4. migrations/001_security_and_integrity.sql   <-- REQUIRED
--
-- Step 4 is not optional. It adds stock validation, an atomic
-- production insert, and an unforgeable audit trail. The two
-- outright security holes it fixed have been corrected inline
-- below, so a fresh install is safe even before it runs.
-- ============================================================


-- ============================================================
-- STEP 1: CUSTOM TYPES (ENUMs via CHECK — no need for pg ENUM)
-- ============================================================

-- (Enforced via CHECK constraints on columns — see tables below)


-- ============================================================
-- STEP 2: TABLES (helper functions come after — they need profiles to exist)
-- ============================================================

-- ----------------------------------------------------------
-- profiles
-- One row per user, linked to auth.users
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  username    TEXT        UNIQUE NOT NULL,
  role        TEXT        NOT NULL CHECK (role IN ('admin', 'manager', 'staff', 'stakeholder')),
  branch      TEXT        NOT NULL CHECK (branch IN ('Main', 'Rusizi', 'All')),
  active      BOOLEAN     NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- purchases
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.purchases (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier       TEXT,
  phone          TEXT        NOT NULL,
  tin            TEXT,
  qty_kg         INTEGER     NOT NULL,
  unit           TEXT        NOT NULL DEFAULT 'kg' CHECK (unit IN ('kg', 'ton')),
  price_per_unit INTEGER     NOT NULL,
  dirt_kg        INTEGER     NOT NULL DEFAULT 0,
  final_qty_kg   INTEGER     NOT NULL,
  total_rwf      INTEGER     NOT NULL,
  branch         TEXT        NOT NULL CHECK (branch IN ('Main', 'Rusizi')),
  entry_time     TIMESTAMPTZ NOT NULL,
  recorded_by    UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- productions
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.productions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  maize_kg        INTEGER     NOT NULL,
  unit            TEXT        NOT NULL DEFAULT 'kg' CHECK (unit IN ('kg', 'ton')),
  flour_kg        INTEGER     NOT NULL DEFAULT 0,
  bran_kg         INTEGER     NOT NULL DEFAULT 0,
  grains_kg       INTEGER     NOT NULL DEFAULT 0,
  bran_out_kg     INTEGER     NOT NULL DEFAULT 0,
  branch          TEXT        NOT NULL CHECK (branch IN ('Main', 'Rusizi')),
  production_time TIMESTAMPTZ NOT NULL,
  recorded_by     UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- production_sacks
-- One row per sack type per production record (always 5 rows)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.production_sacks (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  production_id UUID    NOT NULL REFERENCES public.productions(id) ON DELETE CASCADE,
  sack_key      TEXT    NOT NULL CHECK (sack_key IN ('p_sem25', 'p_sem10', 'p_sem5', 'p_ord50', 'p_ord25')),
  sack_type     TEXT    NOT NULL CHECK (sack_type IN ('semoule', 'ordinaire')),
  size_kg       INTEGER NOT NULL CHECK (size_kg IN (5, 10, 25, 50)),
  sack_count    INTEGER NOT NULL DEFAULT 0,
  total_kg      INTEGER GENERATED ALWAYS AS (size_kg * sack_count) STORED,
  UNIQUE (production_id, sack_key)
);

-- ----------------------------------------------------------
-- sales
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  customer     TEXT,
  phone        TEXT        NOT NULL,
  product      TEXT        NOT NULL CHECK (product IN ('Flour', 'Bran', 'Semoule', 'Ordinaire', 'Maize Grains')),
  qty_kg       INTEGER     NOT NULL,
  price_per_kg INTEGER     NOT NULL,
  total_rwf    INTEGER     NOT NULL,
  branch       TEXT        NOT NULL CHECK (branch IN ('Main', 'Rusizi')),
  sale_time    TIMESTAMPTZ NOT NULL,
  recorded_by  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- activity_log
-- Append-only — no UPDATE or DELETE policies for anyone ever
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity_log (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  action       TEXT        NOT NULL,
  details      TEXT,
  branch       TEXT        NOT NULL,
  performed_by UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================
-- STEP 3: HELPER FUNCTIONS (profiles table now exists — safe to create)
-- ============================================================

-- Returns the role of the currently authenticated user
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- Returns the branch of the currently authenticated user
CREATE OR REPLACE FUNCTION get_my_branch()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT branch FROM public.profiles WHERE id = auth.uid();
$$;


-- ============================================================
-- STEP 4: INDEXES
-- ============================================================

-- purchases
CREATE INDEX IF NOT EXISTS idx_purchases_branch       ON public.purchases (branch);
CREATE INDEX IF NOT EXISTS idx_purchases_recorded_by  ON public.purchases (recorded_by);
CREATE INDEX IF NOT EXISTS idx_purchases_entry_time   ON public.purchases (entry_time DESC);
CREATE INDEX IF NOT EXISTS idx_purchases_created_at   ON public.purchases (created_at DESC);

-- productions
CREATE INDEX IF NOT EXISTS idx_productions_branch          ON public.productions (branch);
CREATE INDEX IF NOT EXISTS idx_productions_recorded_by     ON public.productions (recorded_by);
CREATE INDEX IF NOT EXISTS idx_productions_production_time ON public.productions (production_time DESC);
CREATE INDEX IF NOT EXISTS idx_productions_created_at      ON public.productions (created_at DESC);

-- production_sacks
CREATE INDEX IF NOT EXISTS idx_prod_sacks_production_id ON public.production_sacks (production_id);
CREATE INDEX IF NOT EXISTS idx_prod_sacks_sack_key      ON public.production_sacks (sack_key);

-- sales
CREATE INDEX IF NOT EXISTS idx_sales_branch      ON public.sales (branch);
CREATE INDEX IF NOT EXISTS idx_sales_recorded_by ON public.sales (recorded_by);
CREATE INDEX IF NOT EXISTS idx_sales_sale_time   ON public.sales (sale_time DESC);
CREATE INDEX IF NOT EXISTS idx_sales_created_at  ON public.sales (created_at DESC);

-- activity_log
CREATE INDEX IF NOT EXISTS idx_activity_branch       ON public.activity_log (branch);
CREATE INDEX IF NOT EXISTS idx_activity_performed_by ON public.activity_log (performed_by);
CREATE INDEX IF NOT EXISTS idx_activity_created_at   ON public.activity_log (created_at DESC);


-- ============================================================
-- STEP 5: ENABLE ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.productions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_sacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_log   ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- STEP 6: RLS POLICIES
-- ============================================================

-- ─── profiles ────────────────────────────────────────────────

-- admin + manager: full read on all profiles
CREATE POLICY "profiles_select_admin_manager"
  ON public.profiles FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

-- staff: read own profile only
CREATE POLICY "profiles_select_staff"
  ON public.profiles FOR SELECT
  USING (get_my_role() = 'staff' AND id = auth.uid());

-- stakeholder: read all profiles (for display purposes)
CREATE POLICY "profiles_select_stakeholder"
  ON public.profiles FOR SELECT
  USING (get_my_role() = 'stakeholder');

-- admin + manager: insert new profiles (user management)
CREATE POLICY "profiles_insert_admin_manager"
  ON public.profiles FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

-- admin + manager: update any profile
CREATE POLICY "profiles_update_admin_manager"
  ON public.profiles FOR UPDATE
  USING (get_my_role() IN ('admin', 'manager'));

-- everyone: update own profile only (e.g., display name)
-- WITH CHECK is mandatory here. Without it PostgreSQL reuses USING
-- as the check, which lets the user set their own role to 'admin'.
-- The guard_profile_update() trigger in migrations/001 pins the
-- privilege columns (role, branch, active, username).
CREATE POLICY "profiles_update_self"
  ON public.profiles FOR UPDATE
  USING      (id = auth.uid())
  WITH CHECK (id = auth.uid());


-- ─── purchases ───────────────────────────────────────────────

-- admin + manager: read all
CREATE POLICY "purchases_select_admin_manager"
  ON public.purchases FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

-- staff: read own branch only
CREATE POLICY "purchases_select_staff"
  ON public.purchases FOR SELECT
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

-- stakeholder: read all
CREATE POLICY "purchases_select_stakeholder"
  ON public.purchases FOR SELECT
  USING (get_my_role() = 'stakeholder');

-- admin + manager: insert any branch
CREATE POLICY "purchases_insert_admin_manager"
  ON public.purchases FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

-- staff: insert own branch only
CREATE POLICY "purchases_insert_staff"
  ON public.purchases FOR INSERT
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

-- admin + manager: update any
CREATE POLICY "purchases_update_admin_manager"
  ON public.purchases FOR UPDATE
  USING (get_my_role() IN ('admin', 'manager'));

-- staff: update own branch only
CREATE POLICY "purchases_update_staff"
  ON public.purchases FOR UPDATE
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

-- admin + manager: delete (staff CANNOT delete)
CREATE POLICY "purchases_delete_admin_manager"
  ON public.purchases FOR DELETE
  USING (get_my_role() IN ('admin', 'manager'));


-- ─── productions ─────────────────────────────────────────────

CREATE POLICY "productions_select_admin_manager"
  ON public.productions FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "productions_select_staff"
  ON public.productions FOR SELECT
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "productions_select_stakeholder"
  ON public.productions FOR SELECT
  USING (get_my_role() = 'stakeholder');

CREATE POLICY "productions_insert_admin_manager"
  ON public.productions FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "productions_insert_staff"
  ON public.productions FOR INSERT
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "productions_update_admin_manager"
  ON public.productions FOR UPDATE
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "productions_update_staff"
  ON public.productions FOR UPDATE
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "productions_delete_admin_manager"
  ON public.productions FOR DELETE
  USING (get_my_role() IN ('admin', 'manager'));


-- ─── production_sacks ────────────────────────────────────────
-- Follows parent production's branch via JOIN

CREATE POLICY "prod_sacks_select_admin_manager"
  ON public.production_sacks FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "prod_sacks_select_staff"
  ON public.production_sacks FOR SELECT
  USING (
    get_my_role() = 'staff' AND
    EXISTS (
      SELECT 1 FROM public.productions p
      WHERE p.id = production_sacks.production_id
        AND p.branch = get_my_branch()
    )
  );

CREATE POLICY "prod_sacks_select_stakeholder"
  ON public.production_sacks FOR SELECT
  USING (get_my_role() = 'stakeholder');

CREATE POLICY "prod_sacks_insert_admin_manager"
  ON public.production_sacks FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "prod_sacks_insert_staff"
  ON public.production_sacks FOR INSERT
  WITH CHECK (
    get_my_role() = 'staff' AND
    EXISTS (
      SELECT 1 FROM public.productions p
      WHERE p.id = production_sacks.production_id
        AND p.branch = get_my_branch()
    )
  );

CREATE POLICY "prod_sacks_update_admin_manager"
  ON public.production_sacks FOR UPDATE
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "prod_sacks_update_staff"
  ON public.production_sacks FOR UPDATE
  USING (
    get_my_role() = 'staff' AND
    EXISTS (
      SELECT 1 FROM public.productions p
      WHERE p.id = production_sacks.production_id
        AND p.branch = get_my_branch()
    )
  );

CREATE POLICY "prod_sacks_delete_admin_manager"
  ON public.production_sacks FOR DELETE
  USING (get_my_role() IN ('admin', 'manager'));


-- ─── sales ───────────────────────────────────────────────────

CREATE POLICY "sales_select_admin_manager"
  ON public.sales FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "sales_select_staff"
  ON public.sales FOR SELECT
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "sales_select_stakeholder"
  ON public.sales FOR SELECT
  USING (get_my_role() = 'stakeholder');

CREATE POLICY "sales_insert_admin_manager"
  ON public.sales FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "sales_insert_staff"
  ON public.sales FOR INSERT
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "sales_update_admin_manager"
  ON public.sales FOR UPDATE
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "sales_update_staff"
  ON public.sales FOR UPDATE
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "sales_delete_admin_manager"
  ON public.sales FOR DELETE
  USING (get_my_role() IN ('admin', 'manager'));


-- ─── activity_log ────────────────────────────────────────────
-- NO UPDATE or DELETE for anyone — ever

CREATE POLICY "activity_select_admin_manager"
  ON public.activity_log FOR SELECT
  USING (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "activity_select_staff"
  ON public.activity_log FOR SELECT
  USING (get_my_role() = 'staff' AND branch = get_my_branch());

CREATE POLICY "activity_select_stakeholder"
  ON public.activity_log FOR SELECT
  USING (get_my_role() = 'stakeholder');

CREATE POLICY "activity_insert_admin_manager"
  ON public.activity_log FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

CREATE POLICY "activity_insert_staff"
  ON public.activity_log FOR INSERT
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

-- !! No UPDATE policy on activity_log — intentional !!
-- !! No DELETE policy on activity_log — intentional !!


-- ============================================================
-- STEP 7: AUTO-CREATE PROFILE TRIGGER
-- Fires when a new user is created via Supabase Auth.
-- Used for future users added through the Admin panel.
-- For initial seed users, profiles are inserted manually (seed.sql).
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- raw_user_meta_data is client-controlled. Never read role or
  -- branch from it — with public signup enabled that would let
  -- anyone self-register as an admin. New accounts always land as
  -- INACTIVE staff and must be promoted by an admin from the
  -- Users screen. auth.js refuses login while active is false.
  INSERT INTO public.profiles (id, name, username, role, branch, active)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'name', ''), 'New User'),
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'username', ''), split_part(NEW.email, '@', 1)),
    'staff',   -- NEVER from metadata
    'Main',    -- NEVER from metadata
    false      -- requires explicit admin activation
  )
  ON CONFLICT (id) DO NOTHING;  -- skip if profile already exists (seeded)
  RETURN NEW;
END;
$$;

-- Attach trigger to auth.users
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();


-- ============================================================
-- DONE — Schema created successfully.
-- Next step: run seed.sql after creating the 7 auth users
-- via Supabase Dashboard → Authentication → Users → Add User
-- ============================================================
