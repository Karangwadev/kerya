-- ============================================================
-- KERYA MAIZE â€” Migration 001: Security & Data Integrity
-- Run this ONCE in: Supabase Dashboard â†’ SQL Editor
--
-- Safe to run against an existing database that already has
-- schema.sql + seed.sql applied. Idempotent where possible.
--
-- Fixes:
--   1. Privilege escalation via profiles UPDATE (staff â†’ admin)
--   2. Signup trigger trusting client-supplied role/branch
--   3. Forgeable audit trail (client-supplied recorded_by)
--   4. No stock validation (inventory could go negative)
--   5. Non-atomic production insert
--
-- IMPORTANT: read "STEP 0" before running.
--
-- >>> RUN THIS FILE ONCE, AND BEFORE 002. <<<
-- Forward-only: 002 and 003 replace branch_stock() with a different
-- return type, so re-running 001 afterwards fails with 'cannot change
-- return type of existing function'. That is expected, not a fault.
-- Verified against PostgreSQL 18 on 2 Sep 2026.
-- ============================================================


-- ============================================================
-- STEP 0: PRE-FLIGHT CHECK â€” run this SELECT on its own FIRST
-- ============================================================
-- Step 4 below installs triggers that reject any sale or
-- production that would drive stock negative. If your existing
-- data ALREADY has negative stock, those triggers will block
-- all further entries for that branch until you correct it.
--
-- Run this first and confirm every number is >= 0:
--
--   SELECT 'Main' AS branch, * FROM public.branch_stock('Main')
--   UNION ALL
--   SELECT 'Rusizi', * FROM public.branch_stock('Rusizi');
--
-- (branch_stock is created in STEP 4 â€” so run STEPS 1-4, then
--  the SELECT, then STEP 5 only if the numbers look right.)
-- ============================================================


-- ============================================================
-- STEP 1: FIX PRIVILEGE ESCALATION ON profiles
-- ============================================================
-- The old policy had no WITH CHECK clause, so PostgreSQL reused
-- USING as the check. Both conditions still passed after the
-- change, letting a staff user set their own role to 'admin'.
--
-- Belt and braces: a restrictive WITH CHECK *and* a BEFORE
-- UPDATE trigger that pins the sensitive columns.
-- ------------------------------------------------------------

DROP POLICY IF EXISTS "profiles_update_staff_own" ON public.profiles;
-- schema.sql already creates profiles_update_self (the fix was applied
-- inline there so a fresh install is never vulnerable), so drop that too
-- and this migration stays re-runnable.
DROP POLICY IF EXISTS "profiles_update_self"      ON public.profiles;

-- Staff and stakeholders may update only their own row.
-- The trigger below decides which COLUMNS they may actually change.
CREATE POLICY "profiles_update_self"
  ON public.profiles FOR UPDATE
  USING      (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Guard trigger: the authoritative rule for who can change what.
CREATE OR REPLACE FUNCTION public.guard_profile_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_role TEXT := get_my_role();
BEGIN
  -- Immutable for everyone, including admins.
  NEW.id         := OLD.id;
  NEW.created_at := OLD.created_at;

  IF v_actor_role IN ('admin', 'manager') THEN
    -- Only an admin may grant or revoke the admin role.
    IF (NEW.role = 'admin' OR OLD.role = 'admin')
       AND NEW.role IS DISTINCT FROM OLD.role
       AND v_actor_role <> 'admin' THEN
      RAISE EXCEPTION 'Only an admin can grant or revoke the admin role';
    END IF;

    -- A manager may not deactivate or rename an admin.
    IF OLD.role = 'admin' AND v_actor_role <> 'admin' THEN
      RAISE EXCEPTION 'Only an admin can modify an admin account';
    END IF;

    -- Nobody may deactivate their own account (lock-out guard).
    IF NEW.id = auth.uid() AND OLD.active AND NOT NEW.active THEN
      RAISE EXCEPTION 'You cannot deactivate your own account';
    END IF;

    RETURN NEW;
  END IF;

  -- staff / stakeholder: privilege columns are pinned to their
  -- previous values. They may only edit their display name.
  NEW.role     := OLD.role;
  NEW.branch   := OLD.branch;
  NEW.active   := OLD.active;
  NEW.username := OLD.username;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_profile_update ON public.profiles;
CREATE TRIGGER trg_guard_profile_update
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_profile_update();


-- ============================================================
-- STEP 2: HARDEN THE SIGNUP TRIGGER
-- ============================================================
-- The old trigger read role and branch out of raw_user_meta_data,
-- which is fully client-controlled. If email signup is enabled on
-- the project, anyone could self-register as an admin.
--
-- New behaviour: every auto-created profile is an INACTIVE staff
-- member on the Main branch. An admin promotes and activates them
-- from the Users screen. auth.js already refuses login when
-- profile.active is false, so an unapproved signup can do nothing.
--
-- >>> ALSO DO THIS IN THE DASHBOARD <<<
-- Authentication â†’ Sign In / Providers â†’ disable "Allow new users
-- to sign up" unless you genuinely want public self-registration.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, name, username, role, branch, active)
  VALUES (
    NEW.id,
    -- name is cosmetic, so metadata is acceptable here
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'name', ''), 'New User'),
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'username', ''), split_part(NEW.email, '@', 1)),
    'staff',   -- NEVER from metadata
    'Main',    -- NEVER from metadata
    false      -- requires explicit admin activation
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;


-- ============================================================
-- STEP 3: MAKE THE AUDIT TRAIL UNFORGEABLE
-- ============================================================
-- recorded_by / performed_by were supplied by the browser, so any
-- user could attribute their entries to someone else. Now the
-- database fills them in and RLS rejects anything else.
-- ------------------------------------------------------------

ALTER TABLE public.purchases    ALTER COLUMN recorded_by  SET DEFAULT auth.uid();
ALTER TABLE public.productions  ALTER COLUMN recorded_by  SET DEFAULT auth.uid();
ALTER TABLE public.sales        ALTER COLUMN recorded_by  SET DEFAULT auth.uid();
ALTER TABLE public.activity_log ALTER COLUMN performed_by SET DEFAULT auth.uid();

-- â”€â”€â”€ purchases â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
DROP POLICY IF EXISTS "purchases_insert_admin_manager" ON public.purchases;
DROP POLICY IF EXISTS "purchases_insert_staff"         ON public.purchases;

CREATE POLICY "purchases_insert_admin_manager"
  ON public.purchases FOR INSERT
  WITH CHECK (get_my_role() IN ('admin','manager') AND recorded_by = auth.uid());

CREATE POLICY "purchases_insert_staff"
  ON public.purchases FOR INSERT
  WITH CHECK (get_my_role() = 'staff'
              AND branch = get_my_branch()
              AND recorded_by = auth.uid());

-- Also pin the branch on UPDATE. The old staff UPDATE policy had
-- no WITH CHECK, so a staff member could move a row to the other
-- branch. (USING was reused as the check, which happened to cover
-- this â€” but relying on that is fragile. Made explicit.)
DROP POLICY IF EXISTS "purchases_update_staff" ON public.purchases;
CREATE POLICY "purchases_update_staff"
  ON public.purchases FOR UPDATE
  USING      (get_my_role() = 'staff' AND branch = get_my_branch())
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

-- â”€â”€â”€ productions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
DROP POLICY IF EXISTS "productions_insert_admin_manager" ON public.productions;
DROP POLICY IF EXISTS "productions_insert_staff"         ON public.productions;

CREATE POLICY "productions_insert_admin_manager"
  ON public.productions FOR INSERT
  WITH CHECK (get_my_role() IN ('admin','manager') AND recorded_by = auth.uid());

CREATE POLICY "productions_insert_staff"
  ON public.productions FOR INSERT
  WITH CHECK (get_my_role() = 'staff'
              AND branch = get_my_branch()
              AND recorded_by = auth.uid());

DROP POLICY IF EXISTS "productions_update_staff" ON public.productions;
CREATE POLICY "productions_update_staff"
  ON public.productions FOR UPDATE
  USING      (get_my_role() = 'staff' AND branch = get_my_branch())
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

-- â”€â”€â”€ sales â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
DROP POLICY IF EXISTS "sales_insert_admin_manager" ON public.sales;
DROP POLICY IF EXISTS "sales_insert_staff"         ON public.sales;

CREATE POLICY "sales_insert_admin_manager"
  ON public.sales FOR INSERT
  WITH CHECK (get_my_role() IN ('admin','manager') AND recorded_by = auth.uid());

CREATE POLICY "sales_insert_staff"
  ON public.sales FOR INSERT
  WITH CHECK (get_my_role() = 'staff'
              AND branch = get_my_branch()
              AND recorded_by = auth.uid());

DROP POLICY IF EXISTS "sales_update_staff" ON public.sales;
CREATE POLICY "sales_update_staff"
  ON public.sales FOR UPDATE
  USING      (get_my_role() = 'staff' AND branch = get_my_branch())
  WITH CHECK (get_my_role() = 'staff' AND branch = get_my_branch());

-- â”€â”€â”€ activity_log â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
DROP POLICY IF EXISTS "activity_insert_admin_manager" ON public.activity_log;
DROP POLICY IF EXISTS "activity_insert_staff"         ON public.activity_log;

CREATE POLICY "activity_insert_admin_manager"
  ON public.activity_log FOR INSERT
  WITH CHECK (get_my_role() IN ('admin','manager') AND performed_by = auth.uid());

CREATE POLICY "activity_insert_staff"
  ON public.activity_log FOR INSERT
  WITH CHECK (get_my_role() = 'staff'
              AND branch = get_my_branch()
              AND performed_by = auth.uid());

-- Stakeholders are read-only; they had no insert policy and still don't.


-- ============================================================
-- STEP 4: STOCK VALIDATION
-- ============================================================
-- Mirrors the arithmetic that loadInventory() in script.js used
-- to do in the browser, but as the single source of truth.
--
--   raw maize = purchases.final_qty_kg - productions.maize_kg
--   flour     = productions.flour_kg   - sales of Flour/Semoule/Ordinaire
--   bran      = productions.bran_kg    - sales of Bran
--   grains    = productions.grains_kg  - sales of Maize Grains
--
-- NOTE: productions has both bran_kg ("bran left") and
-- bran_out_kg ("bran out"). The existing inventory screen counted
-- only bran_kg, so that is what is used here. If bran_out_kg is
-- also saleable stock, this needs revisiting â€” see the handover note.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.branch_stock(p_branch TEXT)
RETURNS TABLE (
  raw_maize_kg BIGINT,
  flour_kg     BIGINT,
  bran_kg      BIGINT,
  grains_kg    BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER   -- must see all rows regardless of the caller's RLS
SET search_path = public
AS $$
BEGIN
  -- Don't let a staff member read the other branch's position.
  IF get_my_role() = 'staff' AND p_branch <> get_my_branch() THEN
    RAISE EXCEPTION 'Not authorised to read stock for branch %', p_branch;
  END IF;

  -- Tables are aliased: this function RETURNS TABLE with output columns
  -- called flour_kg, bran_kg and grains_kg, which would otherwise be
  -- ambiguous against the identically-named columns on productions.
  -- (PL/pgSQL only resolves these at run time, so the clash would not
  -- appear until the function was actually called.)
  RETURN QUERY
  SELECT
    COALESCE((SELECT SUM(pu.final_qty_kg) FROM purchases   pu WHERE pu.branch = p_branch), 0)
      - COALESCE((SELECT SUM(pr.maize_kg) FROM productions pr WHERE pr.branch = p_branch), 0),

    COALESCE((SELECT SUM(pr.flour_kg) FROM productions pr WHERE pr.branch = p_branch), 0)
      - COALESCE((SELECT SUM(sa.qty_kg) FROM sales sa
                  WHERE sa.branch = p_branch
                    AND sa.product IN ('Flour','Semoule','Ordinaire')), 0),

    COALESCE((SELECT SUM(pr.bran_kg) FROM productions pr WHERE pr.branch = p_branch), 0)
      - COALESCE((SELECT SUM(sa.qty_kg) FROM sales sa
                  WHERE sa.branch = p_branch AND sa.product = 'Bran'), 0),

    COALESCE((SELECT SUM(pr.grains_kg) FROM productions pr WHERE pr.branch = p_branch), 0)
      - COALESCE((SELECT SUM(sa.qty_kg) FROM sales sa
                  WHERE sa.branch = p_branch AND sa.product = 'Maize Grains'), 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.branch_stock(TEXT) TO authenticated;

-- â”€â”€ Enforcement triggers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- pg_advisory_xact_lock serialises concurrent writes per branch,
-- so two simultaneous sales cannot both read the same stock level
-- and both pass. The lock is released automatically at COMMIT.

CREATE OR REPLACE FUNCTION public.check_production_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.branch));

  SELECT COALESCE((SELECT SUM(final_qty_kg) FROM purchases   WHERE branch = NEW.branch), 0)
       - COALESCE((SELECT SUM(maize_kg)     FROM productions WHERE branch = NEW.branch), 0)
    INTO v_available;

  IF NEW.maize_kg > v_available THEN
    RAISE EXCEPTION
      'Not enough raw maize at % branch: % kg available, % kg requested',
      NEW.branch, v_available, NEW.maize_kg
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_production_stock ON public.productions;
CREATE TRIGGER trg_check_production_stock
  BEFORE INSERT ON public.productions
  FOR EACH ROW
  EXECUTE FUNCTION public.check_production_stock();


CREATE OR REPLACE FUNCTION public.check_sale_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
  v_label     TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.branch));

  IF NEW.product IN ('Flour','Semoule','Ordinaire') THEN
    v_label := 'flour';
    SELECT COALESCE((SELECT SUM(flour_kg) FROM productions WHERE branch = NEW.branch), 0)
         - COALESCE((SELECT SUM(qty_kg)   FROM sales
                     WHERE branch = NEW.branch
                       AND product IN ('Flour','Semoule','Ordinaire')), 0)
      INTO v_available;

  ELSIF NEW.product = 'Bran' THEN
    v_label := 'bran';
    SELECT COALESCE((SELECT SUM(bran_kg) FROM productions WHERE branch = NEW.branch), 0)
         - COALESCE((SELECT SUM(qty_kg)  FROM sales
                     WHERE branch = NEW.branch AND product = 'Bran'), 0)
      INTO v_available;

  ELSIF NEW.product = 'Maize Grains' THEN
    v_label := 'maize grains';
    SELECT COALESCE((SELECT SUM(grains_kg) FROM productions WHERE branch = NEW.branch), 0)
         - COALESCE((SELECT SUM(qty_kg)    FROM sales
                     WHERE branch = NEW.branch AND product = 'Maize Grains'), 0)
      INTO v_available;

  ELSE
    RETURN NEW;  -- unknown product: CHECK constraint already rejects it
  END IF;

  IF NEW.qty_kg > v_available THEN
    RAISE EXCEPTION
      'Not enough % at % branch: % kg available, % kg requested',
      v_label, NEW.branch, v_available, NEW.qty_kg
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_sale_stock ON public.sales;
CREATE TRIGGER trg_check_sale_stock
  BEFORE INSERT ON public.sales
  FOR EACH ROW
  EXECUTE FUNCTION public.check_sale_stock();


-- ============================================================
-- STEP 5: ATOMIC PRODUCTION INSERT
-- ============================================================
-- db.js previously inserted the production row, then the five sack
-- rows, then hand-rolled a "rollback" DELETE in JavaScript if the
-- second call failed. A closed tab between the two calls left an
-- orphaned production. One function, one transaction, no orphans.
--
-- SECURITY INVOKER (the default) is deliberate: RLS still applies,
-- so a staff member still cannot write to the other branch.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_production(
  p_maize_kg        INTEGER,
  p_unit            TEXT,
  p_flour_kg        INTEGER,
  p_bran_kg         INTEGER,
  p_grains_kg       INTEGER,
  p_bran_out_kg     INTEGER,
  p_branch          TEXT,
  p_production_time TIMESTAMPTZ,
  p_sacks           JSONB   -- {"p_sem25": 4, "p_ord50": 2, ...}
)
RETURNS public.productions
LANGUAGE plpgsql
AS $$
DECLARE
  v_production public.productions;
  v_key        TEXT;
  v_meta       JSONB := '{
    "p_sem25": {"sack_type": "semoule",   "size_kg": 25},
    "p_sem10": {"sack_type": "semoule",   "size_kg": 10},
    "p_sem5":  {"sack_type": "semoule",   "size_kg": 5},
    "p_ord50": {"sack_type": "ordinaire", "size_kg": 50},
    "p_ord25": {"sack_type": "ordinaire", "size_kg": 25}
  }'::jsonb;
BEGIN
  INSERT INTO public.productions (
    maize_kg, unit, flour_kg, bran_kg, grains_kg, bran_out_kg,
    branch, production_time, recorded_by
  )
  VALUES (
    p_maize_kg, COALESCE(p_unit, 'kg'),
    COALESCE(p_flour_kg, 0), COALESCE(p_bran_kg, 0),
    COALESCE(p_grains_kg, 0), COALESCE(p_bran_out_kg, 0),
    p_branch, p_production_time, auth.uid()
  )
  RETURNING * INTO v_production;

  FOR v_key IN SELECT jsonb_object_keys(v_meta) LOOP
    INSERT INTO public.production_sacks (
      production_id, sack_key, sack_type, size_kg, sack_count
    )
    VALUES (
      v_production.id,
      v_key,
      v_meta -> v_key ->> 'sack_type',
      (v_meta -> v_key ->> 'size_kg')::INTEGER,
      COALESCE((p_sacks ->> v_key)::INTEGER, 0)
    );
  END LOOP;

  RETURN v_production;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_production(
  INTEGER, TEXT, INTEGER, INTEGER, INTEGER, INTEGER, TEXT, TIMESTAMPTZ, JSONB
) TO authenticated;


-- ============================================================
-- DONE
-- ============================================================
-- Verify with:
--   SELECT 'Main' AS branch, * FROM public.branch_stock('Main')
--   UNION ALL
--   SELECT 'Rusizi', * FROM public.branch_stock('Rusizi');
--
-- Remaining manual steps (see SECURITY.md):
--   * Rotate every seeded account password
--   * Disable public signup in the Auth settings
-- ============================================================
