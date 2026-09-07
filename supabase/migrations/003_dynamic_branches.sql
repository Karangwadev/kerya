-- ============================================================
-- KERYA MAIZE — Migration 003: Dynamic Branches
-- Run in: Supabase Dashboard → SQL Editor, AFTER 002.
--
-- 'Main' and 'Rusizi' were baked into CHECK constraints across six
-- tables, into the stock function, and into the direction of a
-- transfer. Opening a third branch meant a schema change.
--
-- Branches are now rows. Adding one is a data change, made from the
-- Branches screen by an admin.
--
-- Each branch carries a `can_produce` flag, which is what actually
-- distinguishes the two kinds of site:
--
--   can_produce = true   (like Main)
--     buys maize, mills it, holds bulk stock (cleaned maize, bran),
--     packs sacks and dispatches them to other branches.
--
--   can_produce = false  (like Rusizi)
--     receives transfers and sells sacks. Cannot buy maize, mill, or
--     sell bulk products — it has no way to obtain them.
--
-- Nothing about how Main and Rusizi behave changes. They simply
-- become the first two rows rather than hardcoded strings.
-- ============================================================


-- ============================================================
-- STEP 1: THE BRANCHES TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.branches (
  name        TEXT        PRIMARY KEY,
  can_produce BOOLEAN     NOT NULL DEFAULT false,
  active      BOOLEAN     NOT NULL DEFAULT true,
  sort        INTEGER     NOT NULL DEFAULT 100,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT branches_name_not_blank CHECK (length(trim(name)) > 0),
  -- 'All' is the sentinel for "every branch" on a profile. It must
  -- never be a real branch or it would collide with that meaning.
  CONSTRAINT branches_name_not_all CHECK (name <> 'All')
);

INSERT INTO public.branches (name, can_produce, active, sort) VALUES
  ('Main',   true,  true, 1),
  ('Rusizi', false, true, 2)
ON CONFLICT (name) DO NOTHING;

-- Any branch already referenced by existing data must exist as a row,
-- or the foreign keys added in STEP 2 will fail. Adopt strays as
-- non-producing branches; an admin can flip the flag afterwards.
INSERT INTO public.branches (name, can_produce, active, sort)
SELECT DISTINCT b, false, true, 100
  FROM (
    SELECT branch AS b FROM public.purchases
    UNION SELECT branch FROM public.productions
    UNION SELECT branch FROM public.sales
    UNION SELECT branch FROM public.activity_log
    UNION SELECT branch FROM public.profiles WHERE branch <> 'All'
  ) s
 WHERE b IS NOT NULL AND trim(b) <> '' AND b <> 'All'
ON CONFLICT (name) DO NOTHING;

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

-- Everyone signed in reads the branch list; the UI is built from it.
DROP POLICY IF EXISTS "branches_select_all" ON public.branches;
CREATE POLICY "branches_select_all"
  ON public.branches FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Opening or closing a branch is an admin decision.
DROP POLICY IF EXISTS "branches_insert_admin" ON public.branches;
CREATE POLICY "branches_insert_admin"
  ON public.branches FOR INSERT
  WITH CHECK (get_my_role() = 'admin');

DROP POLICY IF EXISTS "branches_update_admin" ON public.branches;
CREATE POLICY "branches_update_admin"
  ON public.branches FOR UPDATE
  USING (get_my_role() = 'admin')
  WITH CHECK (get_my_role() = 'admin');

-- No DELETE policy, deliberately. A branch with history must not
-- vanish — deactivate it instead, so its records keep their meaning.

-- Renaming a branch would orphan every record pointing at it, and the
-- foreign keys below are ON UPDATE CASCADE only for genuine renames.
-- Turning off can_produce while bulk stock or unsent sacks remain
-- would strand them, so that is blocked too.
CREATE OR REPLACE FUNCTION public.guard_branch_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_maize BIGINT;
BEGIN
  IF OLD.can_produce AND NOT NEW.can_produce THEN
    SELECT COALESCE((SELECT SUM(final_qty_kg) FROM purchases   WHERE branch = OLD.name), 0)
         - COALESCE((SELECT SUM(maize_kg)     FROM productions WHERE branch = OLD.name), 0)
         - COALESCE((SELECT SUM(qty_kg)       FROM sales
                      WHERE branch = OLD.name AND product = 'Cleaned Maize'), 0)
      INTO v_maize;

    IF v_maize <> 0 THEN
      RAISE EXCEPTION
        '% still holds % kg of cleaned maize. Clear it before turning off production.',
        OLD.name, v_maize;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_branch_update ON public.branches;
CREATE TRIGGER trg_guard_branch_update
  BEFORE UPDATE ON public.branches
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_branch_update();


-- ── Helpers ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.branch_can_produce(p_branch TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT can_produce FROM public.branches WHERE name = p_branch), false);
$$;

CREATE OR REPLACE FUNCTION public.branch_is_active(p_branch TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT active FROM public.branches WHERE name = p_branch), false);
$$;

GRANT EXECUTE ON FUNCTION public.branch_can_produce(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.branch_is_active(TEXT)  TO authenticated;


-- ============================================================
-- STEP 2: REPLACE HARDCODED CHECKS WITH FOREIGN KEYS
-- ============================================================
-- ON UPDATE CASCADE so an admin can correct a branch's spelling
-- without orphaning its history. No ON DELETE action is needed —
-- there is no DELETE policy on branches.

-- ── purchases ────────────────────────────────────────────────
ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_branch_check;
ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_branch_fkey;
ALTER TABLE public.purchases ADD  CONSTRAINT purchases_branch_fkey
  FOREIGN KEY (branch) REFERENCES public.branches (name) ON UPDATE CASCADE;

-- ── productions ──────────────────────────────────────────────
-- 002 pinned this to 'Main'. Now: any branch that can produce.
ALTER TABLE public.productions DROP CONSTRAINT IF EXISTS productions_branch_check;
ALTER TABLE public.productions DROP CONSTRAINT IF EXISTS productions_branch_fkey;
ALTER TABLE public.productions ADD  CONSTRAINT productions_branch_fkey
  FOREIGN KEY (branch) REFERENCES public.branches (name) ON UPDATE CASCADE;

-- ── sales ────────────────────────────────────────────────────
-- 002 hardcoded "Rusizi sells only sacks". The real rule is that a
-- branch which cannot produce has no way to obtain bulk product.
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_branch_check;
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_rusizi_products;
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_branch_fkey;
ALTER TABLE public.sales ADD  CONSTRAINT sales_branch_fkey
  FOREIGN KEY (branch) REFERENCES public.branches (name) ON UPDATE CASCADE;

-- ── activity_log ─────────────────────────────────────────────
-- Left as a free-text column on purpose: it is an append-only audit
-- trail and must keep its rows even if a branch name is corrected.

-- ── profiles ─────────────────────────────────────────────────
-- Cannot be a plain FK because 'All' is a sentinel, not a branch.
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_branch_check;

CREATE OR REPLACE FUNCTION public.guard_profile_branch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.branch <> 'All'
     AND NOT EXISTS (SELECT 1 FROM public.branches WHERE name = NEW.branch) THEN
    RAISE EXCEPTION 'Unknown branch: %', NEW.branch;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_profile_branch ON public.profiles;
CREATE TRIGGER trg_guard_profile_branch
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_profile_branch();


-- ============================================================
-- STEP 3: TRANSFERS BETWEEN ANY TWO BRANCHES
-- ============================================================
-- 002 fixed the direction as Main → Rusizi. Now any branch may send
-- to any other; the stock check on the sending side is what makes it
-- honest.

ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_from_branch_check;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_to_branch_check;

ALTER TABLE public.transfers ALTER COLUMN from_branch DROP DEFAULT;
ALTER TABLE public.transfers ALTER COLUMN to_branch   DROP DEFAULT;

ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_from_branch_fkey;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_from_branch_fkey
  FOREIGN KEY (from_branch) REFERENCES public.branches (name) ON UPDATE CASCADE;

ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_to_branch_fkey;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_to_branch_fkey
  FOREIGN KEY (to_branch) REFERENCES public.branches (name) ON UPDATE CASCADE;

ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_distinct_branches;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_distinct_branches
  CHECK (from_branch <> to_branch);

CREATE INDEX IF NOT EXISTS idx_transfers_from ON public.transfers (from_branch);
CREATE INDEX IF NOT EXISTS idx_transfers_to   ON public.transfers (to_branch);

-- Dispatch from your own branch; confirm arrivals at your own branch.
DROP POLICY IF EXISTS "transfers_insert" ON public.transfers;
CREATE POLICY "transfers_insert"
  ON public.transfers FOR INSERT
  WITH CHECK (
    dispatched_by = auth.uid()
    AND status = 'pending'
    AND (get_my_role() IN ('admin', 'manager')
         OR (get_my_role() = 'staff' AND from_branch = get_my_branch()))
  );

DROP POLICY IF EXISTS "transfers_update" ON public.transfers;
CREATE POLICY "transfers_update"
  ON public.transfers FOR UPDATE
  USING (
    get_my_role() IN ('admin', 'manager')
    OR (get_my_role() = 'staff' AND to_branch = get_my_branch())
  )
  WITH CHECK (
    get_my_role() IN ('admin', 'manager')
    OR (get_my_role() = 'staff' AND to_branch = get_my_branch())
  );

-- The receiving side must not be able to rewrite what was dispatched.
CREATE OR REPLACE FUNCTION public.guard_transfer_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status = 'confirmed' AND get_my_role() <> 'admin' THEN
    RAISE EXCEPTION 'This transfer is already confirmed. Ask an admin to correct it.';
  END IF;

  IF NEW.status = 'confirmed' AND OLD.status <> 'confirmed' THEN
    NEW.confirmed_at := now();
    NEW.confirmed_by := auth.uid();
  END IF;

  IF get_my_role() NOT IN ('admin', 'manager') THEN
    NEW.product       := OLD.product;
    NEW.size_kg       := OLD.size_kg;
    NEW.sacks_sent    := OLD.sacks_sent;
    NEW.from_branch   := OLD.from_branch;
    NEW.to_branch     := OLD.to_branch;
    NEW.dispatched_at := OLD.dispatched_at;
    NEW.dispatched_by := OLD.dispatched_by;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================
-- STEP 4: STOCK, GENERALISED
-- ============================================================
--   Bulk (producing branches only)
--     Cleaned Maize = purchases − maize milled − cleaned maize sold
--     Bran          = bran from semoule runs − bran sold
--
--   Sacks (every branch)
--     = packed here
--     + confirmed transfers IN
--     − transfers OUT (pending ones have already left)
--     − sold here
--
-- Note the sack formula now works for any branch without a special
-- case: Main happens to pack and dispatch, Rusizi happens to receive
-- and sell, and a branch that does both needs no new code.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.branch_stock(p_branch TEXT)
RETURNS TABLE (
  product TEXT,
  size_kg INTEGER,
  sacks   BIGINT,
  kg      BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF get_my_role() = 'staff' AND p_branch <> get_my_branch() THEN
    RAISE EXCEPTION 'Not authorised to read stock for branch %', p_branch;
  END IF;

  IF branch_can_produce(p_branch) THEN
    -- Tables are aliased throughout: this function RETURNS TABLE with an
    -- output column called "product", so a bare `product` in a subquery
    -- is ambiguous between that and sales.product.
    RETURN QUERY
    SELECT 'Cleaned Maize'::TEXT, NULL::INTEGER, NULL::BIGINT,
           COALESCE((SELECT SUM(pu.final_qty_kg) FROM purchases   pu WHERE pu.branch = p_branch), 0)
         - COALESCE((SELECT SUM(pr.maize_kg)     FROM productions pr WHERE pr.branch = p_branch), 0)
         - COALESCE((SELECT SUM(sa.qty_kg)       FROM sales       sa
                      WHERE sa.branch = p_branch AND sa.product = 'Cleaned Maize'), 0);

    RETURN QUERY
    SELECT 'Bran'::TEXT, NULL::INTEGER, NULL::BIGINT,
           COALESCE((SELECT SUM(pr.bran_kg) FROM productions pr WHERE pr.branch = p_branch), 0)
         - COALESCE((SELECT SUM(sa.qty_kg)  FROM sales       sa
                      WHERE sa.branch = p_branch AND sa.product = 'Bran'), 0);
  END IF;

  RETURN QUERY
  WITH counted AS (
    SELECT
      z.product,
      z.size_kg,
        COALESCE((SELECT SUM(ps.sack_count)
                    FROM production_sacks ps
                    JOIN productions pr ON pr.id = ps.production_id
                   WHERE pr.product_type = z.product
                     AND ps.size_kg      = z.size_kg
                     AND pr.branch       = p_branch), 0)
      + COALESCE((SELECT SUM(t.sacks_received) FROM transfers t
                   WHERE t.product   = z.product AND t.size_kg = z.size_kg
                     AND t.to_branch = p_branch  AND t.status  = 'confirmed'), 0)
      - COALESCE((SELECT SUM(t.sacks_sent) FROM transfers t
                   WHERE t.product     = z.product AND t.size_kg = z.size_kg
                     AND t.from_branch = p_branch  AND t.status <> 'cancelled'), 0)
      - COALESCE((SELECT SUM(s.sack_count) FROM sales s
                   WHERE s.branch  = p_branch AND s.product = z.product
                     AND s.size_kg = z.size_kg), 0)
      AS sacks
    FROM sack_sizes z
  )
  SELECT c.product, c.size_kg, c.sacks, c.sacks * c.size_kg
    FROM counted c
   ORDER BY c.product, c.size_kg DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.branch_stock(TEXT) TO authenticated;


-- ============================================================
-- STEP 5: ENFORCEMENT, GENERALISED
-- ============================================================

-- ── Only producing, active branches may mill ─────────────────
-- NOTE: whether the stock cap itself should exist is still an open
-- question for the owners (see SECURITY.md). Dropping this trigger
-- removes the cap; the branch rules would then need reinstating
-- separately.
CREATE OR REPLACE FUNCTION public.check_production_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  IF NOT branch_is_active(NEW.branch) THEN
    RAISE EXCEPTION '% is not an active branch', NEW.branch;
  END IF;

  IF NOT branch_can_produce(NEW.branch) THEN
    RAISE EXCEPTION '% is not a production branch', NEW.branch
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.branch));

  SELECT COALESCE((SELECT SUM(final_qty_kg) FROM purchases   WHERE branch = NEW.branch), 0)
       - COALESCE((SELECT SUM(maize_kg)     FROM productions WHERE branch = NEW.branch), 0)
       - COALESCE((SELECT SUM(qty_kg)       FROM sales
                    WHERE branch = NEW.branch AND product = 'Cleaned Maize'), 0)
    INTO v_available;

  IF NEW.maize_kg > v_available THEN
    RAISE EXCEPTION
      'Not enough cleaned maize at %: % kg available, % kg requested',
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


-- ── Only producing branches may buy maize ────────────────────
CREATE OR REPLACE FUNCTION public.check_purchase_branch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT branch_is_active(NEW.branch) THEN
    RAISE EXCEPTION '% is not an active branch', NEW.branch;
  END IF;

  IF NOT branch_can_produce(NEW.branch) THEN
    RAISE EXCEPTION
      '% cannot buy maize — it has no mill, so the maize could never be used',
      NEW.branch
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_purchase_branch ON public.purchases;
CREATE TRIGGER trg_check_purchase_branch
  BEFORE INSERT ON public.purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.check_purchase_branch();


-- ── Sales ────────────────────────────────────────────────────
-- Replaces the hardcoded "Rusizi sells only sacks" constraint: a
-- non-producing branch has no way to obtain bulk product at all.
CREATE OR REPLACE FUNCTION public.check_sale_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  IF NOT branch_is_active(NEW.branch) THEN
    RAISE EXCEPTION '% is not an active branch', NEW.branch;
  END IF;

  IF NEW.product = 'Flour' THEN
    RAISE EXCEPTION
      'Flour is no longer a sold product. Use Semoule or Ordinaire.'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.price_basis = 'kg' AND NOT branch_can_produce(NEW.branch) THEN
    RAISE EXCEPTION
      '% only sells Semoule and Ordinaire — it receives sacks and does not mill',
      NEW.branch
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.branch));

  IF NEW.price_basis = 'sack' THEN
    v_available := public.sacks_in_stock(NEW.branch, NEW.product, NEW.size_kg);
    IF NEW.sack_count > v_available THEN
      RAISE EXCEPTION
        'Not enough % % kg sacks at %: % in stock, % requested',
        NEW.product, NEW.size_kg, NEW.branch, v_available, NEW.sack_count
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  SELECT s.kg INTO v_available
    FROM public.branch_stock(NEW.branch) s
   WHERE s.product = NEW.product AND s.size_kg IS NULL;

  IF v_available IS NULL THEN
    RAISE EXCEPTION '% is not stocked at % branch', NEW.product, NEW.branch
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.qty_kg > v_available THEN
    RAISE EXCEPTION
      'Not enough % at %: % kg available, % kg requested',
      NEW.product, NEW.branch, v_available, NEW.qty_kg
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


-- ── A dispatch may not send sacks the sender does not have ───
CREATE OR REPLACE FUNCTION public.check_transfer_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  IF NOT branch_is_active(NEW.from_branch) THEN
    RAISE EXCEPTION '% is not an active branch', NEW.from_branch;
  END IF;
  IF NOT branch_is_active(NEW.to_branch) THEN
    RAISE EXCEPTION '% is not an active branch', NEW.to_branch;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.from_branch));

  v_available := public.sacks_in_stock(NEW.from_branch, NEW.product, NEW.size_kg);

  IF NEW.sacks_sent > v_available THEN
    RAISE EXCEPTION
      'Not enough % % kg sacks at %: % in stock, % being sent',
      NEW.product, NEW.size_kg, NEW.from_branch, v_available, NEW.sacks_sent
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_transfer_stock ON public.transfers;
CREATE TRIGGER trg_check_transfer_stock
  BEFORE INSERT ON public.transfers
  FOR EACH ROW
  EXECUTE FUNCTION public.check_transfer_stock();


-- ============================================================
-- STEP 6: PRODUCTION TAKES A BRANCH
-- ============================================================
-- 002's version hardcoded 'Main'. The old signature is dropped so a
-- stale client cannot keep calling it.

DROP FUNCTION IF EXISTS public.create_production(
  TEXT, INTEGER, NUMERIC, TIMESTAMPTZ, JSONB
);

CREATE OR REPLACE FUNCTION public.create_production(
  p_product_type    TEXT,
  p_maize_kg        INTEGER,
  p_processing_rate NUMERIC,     -- NULL for Ordinaire
  p_branch          TEXT,
  p_production_time TIMESTAMPTZ,
  p_sacks           JSONB        -- {"25": 30, "10": 4}  keys are sack sizes
)
RETURNS public.productions
LANGUAGE plpgsql
AS $$
DECLARE
  v_production public.productions;
  v_output_kg  INTEGER;
  v_bran_kg    INTEGER;
  v_size       TEXT;
  v_count      INTEGER;
  v_sack_kg    BIGINT := 0;
BEGIN
  IF p_product_type NOT IN ('Semoule', 'Ordinaire') THEN
    RAISE EXCEPTION 'Unknown product type: %', p_product_type;
  END IF;

  IF p_maize_kg IS NULL OR p_maize_kg <= 0 THEN
    RAISE EXCEPTION 'Maize processed must be greater than zero';
  END IF;

  IF p_product_type = 'Semoule' THEN
    IF p_processing_rate IS NULL OR p_processing_rate <= 0 OR p_processing_rate > 1 THEN
      RAISE EXCEPTION 'Semoule needs a processing rate between 0 and 100%%';
    END IF;
    v_output_kg := ROUND(p_maize_kg * p_processing_rate);
    v_bran_kg   := p_maize_kg - v_output_kg;
  ELSE
    -- Ordinaire is a mixture of everything — nothing is separated out.
    v_output_kg := p_maize_kg;
    v_bran_kg   := 0;
    p_processing_rate := NULL;
  END IF;

  INSERT INTO public.productions (
    maize_kg, product_type, processing_rate, output_kg, bran_kg,
    branch, production_time, recorded_by
  )
  VALUES (
    p_maize_kg, p_product_type, p_processing_rate, v_output_kg, v_bran_kg,
    p_branch, p_production_time, auth.uid()
  )
  RETURNING * INTO v_production;

  FOR v_size IN SELECT jsonb_object_keys(COALESCE(p_sacks, '{}'::jsonb)) LOOP
    v_count := COALESCE((p_sacks ->> v_size)::INTEGER, 0);
    CONTINUE WHEN v_count <= 0;

    IF NOT EXISTS (
      SELECT 1 FROM public.sack_sizes
       WHERE product = p_product_type AND size_kg = v_size::INTEGER
    ) THEN
      RAISE EXCEPTION '% does not come in % kg sacks', p_product_type, v_size;
    END IF;

    INSERT INTO public.production_sacks (production_id, size_kg, sack_count)
    VALUES (v_production.id, v_size::INTEGER, v_count);

    v_sack_kg := v_sack_kg + (v_size::INTEGER * v_count);
  END LOOP;

  IF v_sack_kg > v_output_kg THEN
    RAISE EXCEPTION
      'Sacks add up to % kg but only % kg of % was produced',
      v_sack_kg, v_output_kg, p_product_type
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_production;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_production(
  TEXT, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, JSONB
) TO authenticated;


-- ============================================================
-- DONE
-- ============================================================
-- Opening a branch is now a data change:
--
--   INSERT INTO public.branches (name, can_produce, sort)
--   VALUES ('Karongi', false, 3);
--
-- or from the Branches screen as an admin.
--
-- Verify:
--   SELECT b.name, b.can_produce, b.active, s.*
--     FROM public.branches b, LATERAL public.branch_stock(b.name) s
--    ORDER BY b.sort, s.product, s.size_kg DESC;
-- ============================================================
