-- ============================================================
-- KERYA MAIZE — Migration 002: Product & Stock Model
-- Run in: Supabase Dashboard → SQL Editor, AFTER 001.
--
-- Rebuilds the product model around how the plant actually works:
--
--   * Purchases are in kg. Always. No tons.
--   * Milling produces EITHER Semoule OR Ordinaire, never both.
--       - Semoule has a processing rate (default 68%). The rest
--         of the maize comes out as bran.
--       - Ordinaire is a mixture of everything: 100% yield, no bran.
--   * Semoule and Ordinaire are stocked and sold AS SACKS of a
--     given size, not as loose kg.
--       - Semoule:   25kg, 10kg, 5kg
--       - Ordinaire: 50kg, 25kg
--   * Cleaned Maize is purchased maize with the waste taken out.
--     It is either milled or sold as-is.
--   * Production happens at Main only. Rusizi sells what Main
--     transfers to it, and nothing else.
--   * "Maize Grains" is renamed "Cleaned Maize" throughout.
--
-- >>> READ "STEP 0" BEFORE RUNNING. <<<
--
-- >>> RUN THIS FILE ONCE. <<<
-- It is forward-only: it drops columns it also reads (purchases.unit at
-- STEP 3, productions.flour_kg at STEP 4), so a second run fails with
-- 'column "unit" does not exist'. That is expected, not a fault — the
-- work is already done. To change a function defined here, run just its
-- CREATE OR REPLACE block rather than the whole file.
-- Verified against PostgreSQL 18 on 2 Sep 2026.
-- ============================================================


-- ============================================================
-- STEP 0: EXISTING DATA
-- ============================================================
-- This migration CONVERTS existing rows rather than dropping them.
-- The conversions are best-effort guesses about data that predates
-- the current model, and you should check them afterwards:
--
--   productions  → product_type is inferred from which sacks were
--                  recorded (any semoule sack ⇒ 'Semoule', else
--                  'Ordinaire'). processing_rate is back-computed
--                  from flour_kg / maize_kg.
--   sales        → 'Maize Grains' becomes 'Cleaned Maize'.
--                  'Flour' is kept as a legacy value so historical
--                  rows stay truthful; it is no longer offered in
--                  the UI and cannot be entered again.
--   grains_kg    → dropped from productions. Cleaned Maize stock is
--                  now derived from purchases, not production.
--
-- If the current contents are only test data, it is cleaner to
-- start fresh. Run this FIRST, then the rest of the file:
--
--   TRUNCATE public.production_sacks, public.productions,
--            public.sales, public.purchases, public.activity_log
--     RESTART IDENTITY CASCADE;
--
-- ============================================================


-- ============================================================
-- STEP 1: DROP THE OBJECTS 002 REPLACES
-- ============================================================
-- The stock rules change shape completely, so 001's versions go.
-- Recreated further down.

DROP TRIGGER  IF EXISTS trg_check_sale_stock       ON public.sales;
DROP TRIGGER  IF EXISTS trg_check_production_stock ON public.productions;
DROP FUNCTION IF EXISTS public.check_sale_stock();
DROP FUNCTION IF EXISTS public.check_production_stock();
DROP FUNCTION IF EXISTS public.branch_stock(TEXT);
DROP FUNCTION IF EXISTS public.create_production(
  INTEGER, TEXT, INTEGER, INTEGER, INTEGER, INTEGER, TEXT, TIMESTAMPTZ, JSONB
);


-- ============================================================
-- STEP 2: REFERENCE DATA — which sack sizes exist per product
-- ============================================================

CREATE TABLE IF NOT EXISTS public.sack_sizes (
  product TEXT    NOT NULL CHECK (product IN ('Semoule', 'Ordinaire')),
  size_kg INTEGER NOT NULL CHECK (size_kg > 0),
  sort    INTEGER NOT NULL,
  PRIMARY KEY (product, size_kg)
);

INSERT INTO public.sack_sizes (product, size_kg, sort) VALUES
  ('Semoule',   25, 1),
  ('Semoule',   10, 2),
  ('Semoule',    5, 3),
  ('Ordinaire', 50, 1),
  ('Ordinaire', 25, 2)
ON CONFLICT (product, size_kg) DO NOTHING;

ALTER TABLE public.sack_sizes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sack_sizes_select_all" ON public.sack_sizes;
CREATE POLICY "sack_sizes_select_all"
  ON public.sack_sizes FOR SELECT
  USING (auth.uid() IS NOT NULL);   -- reference data, readable by any signed-in user


-- ============================================================
-- STEP 3: PURCHASES — kg only
-- ============================================================
-- Everything is bought, weighed and priced by the kilo. The unit
-- column allowed 'ton', and the browser silently multiplied by
-- 1000 before storing — so the stored unit did not describe the
-- stored number. Removing the column removes the ambiguity.

UPDATE public.purchases SET unit = 'kg' WHERE unit <> 'kg';
ALTER TABLE public.purchases DROP COLUMN IF EXISTS unit;

-- Waste can never equal or exceed the delivery.
ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_qty_positive;
ALTER TABLE public.purchases ADD  CONSTRAINT purchases_qty_positive
  CHECK (qty_kg > 0 AND dirt_kg >= 0 AND final_qty_kg > 0 AND final_qty_kg = qty_kg - dirt_kg);


-- ============================================================
-- STEP 4: PRODUCTIONS — one product per run, Main only
-- ============================================================

ALTER TABLE public.productions
  ADD COLUMN IF NOT EXISTS product_type    TEXT,
  ADD COLUMN IF NOT EXISTS processing_rate NUMERIC(5,4),
  ADD COLUMN IF NOT EXISTS output_kg       INTEGER;

-- ── Convert existing rows ────────────────────────────────────
-- Any semoule sack recorded ⇒ it was a semoule run.
UPDATE public.productions p
   SET product_type = CASE
         WHEN EXISTS (
           SELECT 1 FROM public.production_sacks s
            WHERE s.production_id = p.id
              AND s.sack_type = 'semoule'
              AND s.sack_count > 0
         ) THEN 'Semoule'
         ELSE 'Ordinaire'
       END
 WHERE product_type IS NULL;

UPDATE public.productions
   SET output_kg = COALESCE(NULLIF(flour_kg, 0), maize_kg)
 WHERE output_kg IS NULL;

-- Back-compute the rate for semoule runs; ordinaire has none.
UPDATE public.productions
   SET processing_rate = CASE
         WHEN product_type = 'Semoule' AND maize_kg > 0
           THEN LEAST(1.0, ROUND(output_kg::NUMERIC / maize_kg, 4))
         ELSE NULL
       END
 WHERE processing_rate IS NULL AND product_type = 'Semoule';

ALTER TABLE public.productions
  ALTER COLUMN product_type SET NOT NULL,
  ALTER COLUMN output_kg    SET NOT NULL;

ALTER TABLE public.productions DROP CONSTRAINT IF EXISTS productions_product_type_check;
ALTER TABLE public.productions ADD  CONSTRAINT productions_product_type_check
  CHECK (product_type IN ('Semoule', 'Ordinaire'));

-- Ordinaire separates nothing out, so any bran on a converted
-- ordinaire row is an artefact of the old combined model.
UPDATE public.productions SET bran_kg = 0
 WHERE product_type = 'Ordinaire' AND bran_kg <> 0;

-- Semoule must carry a rate and may carry bran.
-- Ordinaire is a mixture of everything: no rate, no bran, 100% yield.
ALTER TABLE public.productions DROP CONSTRAINT IF EXISTS productions_rate_rules;
ALTER TABLE public.productions ADD  CONSTRAINT productions_rate_rules CHECK (
  (product_type = 'Semoule'
     AND processing_rate IS NOT NULL
     AND processing_rate > 0 AND processing_rate <= 1)
  OR
  (product_type = 'Ordinaire'
     AND processing_rate IS NULL
     AND bran_kg = 0)
);

-- Production is a Main-branch activity. Rusizi only receives.
UPDATE public.productions SET branch = 'Main' WHERE branch <> 'Main';
ALTER TABLE public.productions DROP CONSTRAINT IF EXISTS productions_branch_check;
ALTER TABLE public.productions ADD  CONSTRAINT productions_branch_check
  CHECK (branch = 'Main');

-- flour_kg is superseded by output_kg; grains are no longer a
-- production output (Cleaned Maize now derives from purchases);
-- bran_out_kg was the ambiguous second bran column flagged in 001.
ALTER TABLE public.productions
  DROP COLUMN IF EXISTS flour_kg,
  DROP COLUMN IF EXISTS grains_kg,
  DROP COLUMN IF EXISTS bran_out_kg,
  DROP COLUMN IF EXISTS unit;


-- ============================================================
-- STEP 5: PRODUCTION SACKS — keyed by size, product from parent
-- ============================================================
-- sack_key ('p_sem25') and sack_type duplicated what the parent
-- production and the size already say. One source of truth.
-- size_kg already holds the right value, so the columns just go.
-- (total_kg is GENERATED from size_kg * sack_count and is unaffected.)

-- Collapse any duplicate sizes first — the old schema allowed both
-- p_sem25 and p_ord25, which become one row per size once the key
-- is gone. They can only coexist on a row that predates the
-- one-product-per-run rule, so they belong to the same run anyway.
WITH merged AS (
  -- No min(uuid) aggregate exists in Postgres, so pick the lowest id
  -- by ordering inside array_agg and taking the first element.
  SELECT production_id, size_kg, SUM(sack_count) AS total,
         (ARRAY_AGG(id ORDER BY id))[1] AS keep_id
    FROM public.production_sacks
   GROUP BY production_id, size_kg
  HAVING COUNT(*) > 1
)
UPDATE public.production_sacks ps
   SET sack_count = m.total
  FROM merged m
 WHERE ps.id = m.keep_id;

DELETE FROM public.production_sacks ps
 USING (
   SELECT production_id, size_kg, (ARRAY_AGG(id ORDER BY id))[1] AS keep_id
     FROM public.production_sacks
    GROUP BY production_id, size_kg
   HAVING COUNT(*) > 1
 ) m
 WHERE ps.production_id = m.production_id
   AND ps.size_kg       = m.size_kg
   AND ps.id           <> m.keep_id;

ALTER TABLE public.production_sacks DROP COLUMN IF EXISTS sack_key;
ALTER TABLE public.production_sacks DROP COLUMN IF EXISTS sack_type;

ALTER TABLE public.production_sacks DROP CONSTRAINT IF EXISTS production_sacks_unique_size;
ALTER TABLE public.production_sacks ADD  CONSTRAINT production_sacks_unique_size
  UNIQUE (production_id, size_kg);

ALTER TABLE public.production_sacks DROP CONSTRAINT IF EXISTS production_sacks_count_positive;
ALTER TABLE public.production_sacks ADD  CONSTRAINT production_sacks_count_positive
  CHECK (sack_count >= 0);


-- ============================================================
-- STEP 6: SALES — sacks for milled product, kg for bulk
-- ============================================================

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS size_kg     INTEGER,
  ADD COLUMN IF NOT EXISTS sack_count  INTEGER,
  ADD COLUMN IF NOT EXISTS unit_price  INTEGER,
  ADD COLUMN IF NOT EXISTS price_basis TEXT;

-- Maize Grains and Cleaned Maize are the same product.
UPDATE public.sales SET product = 'Cleaned Maize' WHERE product = 'Maize Grains';

-- Carry the old per-kg pricing across.
UPDATE public.sales
   SET unit_price  = COALESCE(unit_price, price_per_kg),
       price_basis = COALESCE(price_basis, 'kg')
 WHERE unit_price IS NULL OR price_basis IS NULL;

ALTER TABLE public.sales
  ALTER COLUMN unit_price  SET NOT NULL,
  ALTER COLUMN price_basis SET NOT NULL;

ALTER TABLE public.sales DROP COLUMN IF EXISTS price_per_kg;

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_product_check;
ALTER TABLE public.sales ADD  CONSTRAINT sales_product_check
  -- 'Flour' is legacy: kept so historical rows remain truthful,
  -- never offered in the UI. New sales cannot use it (see below).
  CHECK (product IN ('Semoule', 'Ordinaire', 'Bran', 'Cleaned Maize', 'Flour'));

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_price_basis_check;
ALTER TABLE public.sales ADD  CONSTRAINT sales_price_basis_check
  CHECK (price_basis IN ('sack', 'kg'));

-- Sacked products carry a size and a count and are priced per sack.
-- Bulk products carry neither and are priced per kg.
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_sack_rules;
ALTER TABLE public.sales ADD  CONSTRAINT sales_sack_rules CHECK (
  (price_basis = 'sack'
     AND product IN ('Semoule', 'Ordinaire')
     AND size_kg IS NOT NULL AND sack_count IS NOT NULL AND sack_count > 0
     AND qty_kg = size_kg * sack_count)
  OR
  (price_basis = 'kg'
     AND size_kg IS NULL AND sack_count IS NULL
     AND qty_kg > 0)
);

-- Rusizi sells only what Main can send it.
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_rusizi_products;
ALTER TABLE public.sales ADD  CONSTRAINT sales_rusizi_products CHECK (
  branch <> 'Rusizi' OR product IN ('Semoule', 'Ordinaire')
);


-- ============================================================
-- STEP 7: TRANSFERS — Main dispatches, Rusizi confirms
-- ============================================================
-- Two-step on purpose. Main records what left; Rusizi records what
-- actually arrived, which may be less. Main's stock falls at
-- dispatch, Rusizi's rises at confirmation, and the difference is
-- reported as a variance rather than quietly disappearing.

CREATE TABLE IF NOT EXISTS public.transfers (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  product        TEXT        NOT NULL CHECK (product IN ('Semoule', 'Ordinaire')),
  size_kg        INTEGER     NOT NULL,
  sacks_sent     INTEGER     NOT NULL CHECK (sacks_sent > 0),
  sacks_received INTEGER              CHECK (sacks_received >= 0),
  status         TEXT        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'confirmed', 'cancelled')),
  note           TEXT,
  from_branch    TEXT        NOT NULL DEFAULT 'Main'   CHECK (from_branch = 'Main'),
  to_branch      TEXT        NOT NULL DEFAULT 'Rusizi' CHECK (to_branch   = 'Rusizi'),
  dispatched_at  TIMESTAMPTZ NOT NULL,
  dispatched_by  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  confirmed_at   TIMESTAMPTZ,
  confirmed_by   UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  FOREIGN KEY (product, size_kg) REFERENCES public.sack_sizes (product, size_kg),

  -- A confirmed transfer must say how much arrived; a pending one must not.
  CONSTRAINT transfers_status_rules CHECK (
    (status = 'confirmed' AND sacks_received IS NOT NULL AND confirmed_at IS NOT NULL)
    OR
    (status IN ('pending', 'cancelled') AND sacks_received IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_transfers_status     ON public.transfers (status);
CREATE INDEX IF NOT EXISTS idx_transfers_product    ON public.transfers (product, size_kg);
CREATE INDEX IF NOT EXISTS idx_transfers_dispatched ON public.transfers (dispatched_at DESC);

ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;

-- Everyone signed in can read transfers — both ends need to see them.
DROP POLICY IF EXISTS "transfers_select_all" ON public.transfers;
CREATE POLICY "transfers_select_all"
  ON public.transfers FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Only Main-side users dispatch.
DROP POLICY IF EXISTS "transfers_insert" ON public.transfers;
CREATE POLICY "transfers_insert"
  ON public.transfers FOR INSERT
  WITH CHECK (
    dispatched_by = auth.uid()
    AND status = 'pending'
    AND (get_my_role() IN ('admin', 'manager')
         OR (get_my_role() = 'staff' AND get_my_branch() = 'Main'))
  );

-- Only Rusizi-side users (or admin/manager) confirm.
DROP POLICY IF EXISTS "transfers_update" ON public.transfers;
CREATE POLICY "transfers_update"
  ON public.transfers FOR UPDATE
  USING (
    get_my_role() IN ('admin', 'manager')
    OR (get_my_role() = 'staff' AND get_my_branch() = 'Rusizi')
  )
  WITH CHECK (
    get_my_role() IN ('admin', 'manager')
    OR (get_my_role() = 'staff' AND get_my_branch() = 'Rusizi')
  );

-- A confirmed transfer is a settled record between two branches.
-- Reopening one would silently move stock at both ends.
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

  -- What was dispatched is Main's record and is not Rusizi's to edit.
  IF get_my_role() NOT IN ('admin', 'manager') THEN
    NEW.product       := OLD.product;
    NEW.size_kg       := OLD.size_kg;
    NEW.sacks_sent    := OLD.sacks_sent;
    NEW.dispatched_at := OLD.dispatched_at;
    NEW.dispatched_by := OLD.dispatched_by;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_transfer_update ON public.transfers;
CREATE TRIGGER trg_guard_transfer_update
  BEFORE UPDATE ON public.transfers
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_transfer_update();


-- ============================================================
-- STEP 8: STOCK
-- ============================================================
-- One function, one definition of what is in the store. The UI,
-- the reports and the enforcement triggers all read from here, so
-- they cannot drift apart.
--
--   Main
--     Cleaned Maize = purchases (net of waste)
--                     − maize milled − cleaned maize sold
--     Bran          = bran from semoule runs − bran sold
--     Semoule /
--     Ordinaire     = sacks produced − sacks sold − sacks dispatched
--
--   Rusizi
--     Semoule /
--     Ordinaire     = sacks CONFIRMED received − sacks sold
--                     (pending transfers are not yet stock)
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

  IF p_branch = 'Main' THEN
    -- Tables are aliased throughout: this function RETURNS TABLE with an
    -- output column called "product", so a bare `product` in a subquery
    -- is ambiguous between that and sales.product.
    RETURN QUERY
    SELECT 'Cleaned Maize'::TEXT, NULL::INTEGER, NULL::BIGINT,
           COALESCE((SELECT SUM(pu.final_qty_kg) FROM purchases   pu WHERE pu.branch = 'Main'), 0)
         - COALESCE((SELECT SUM(pr.maize_kg)     FROM productions pr WHERE pr.branch = 'Main'), 0)
         - COALESCE((SELECT SUM(sa.qty_kg)       FROM sales       sa
                      WHERE sa.branch = 'Main' AND sa.product = 'Cleaned Maize'), 0);

    RETURN QUERY
    SELECT 'Bran'::TEXT, NULL::INTEGER, NULL::BIGINT,
           COALESCE((SELECT SUM(pr.bran_kg) FROM productions pr WHERE pr.branch = 'Main'), 0)
         - COALESCE((SELECT SUM(sa.qty_kg)  FROM sales       sa
                      WHERE sa.branch = 'Main' AND sa.product = 'Bran'), 0);
  END IF;

  RETURN QUERY
  WITH counted AS (
    SELECT
      z.product,
      z.size_kg,
      CASE WHEN p_branch = 'Main' THEN
        COALESCE((SELECT SUM(ps.sack_count)
                    FROM production_sacks ps
                    JOIN productions pr ON pr.id = ps.production_id
                   WHERE pr.product_type = z.product AND ps.size_kg = z.size_kg), 0)
      - COALESCE((SELECT SUM(t.sacks_sent) FROM transfers t
                   WHERE t.product = z.product AND t.size_kg = z.size_kg
                     AND t.status <> 'cancelled'), 0)
      ELSE
        COALESCE((SELECT SUM(t.sacks_received) FROM transfers t
                   WHERE t.product = z.product AND t.size_kg = z.size_kg
                     AND t.status = 'confirmed'), 0)
      END
      - COALESCE((SELECT SUM(s.sack_count) FROM sales s
                   WHERE s.branch = p_branch AND s.product = z.product
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

-- Convenience wrapper: sacks in stock for one product/size/branch.
CREATE OR REPLACE FUNCTION public.sacks_in_stock(
  p_branch TEXT, p_product TEXT, p_size_kg INTEGER
)
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT s.sacks FROM public.branch_stock(p_branch) s
     WHERE s.product = p_product AND s.size_kg = p_size_kg
  ), 0);
$$;

GRANT EXECUTE ON FUNCTION public.sacks_in_stock(TEXT, TEXT, INTEGER) TO authenticated;


-- ============================================================
-- STEP 9: ENFORCEMENT
-- ============================================================
-- pg_advisory_xact_lock serialises writes per branch so two
-- concurrent sales cannot both read the same balance and pass.

-- ── Production may not mill maize that is not in the store ───
-- NOTE: whether this cap should exist at all is still an open
-- question for the owners. If they want milling uncapped, drop
-- trg_check_production_stock and nothing else changes.
CREATE OR REPLACE FUNCTION public.check_production_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_Main'));

  SELECT COALESCE((SELECT SUM(final_qty_kg) FROM purchases   WHERE branch = 'Main'), 0)
       - COALESCE((SELECT SUM(maize_kg)     FROM productions WHERE branch = 'Main'), 0)
       - COALESCE((SELECT SUM(qty_kg)       FROM sales
                    WHERE branch = 'Main' AND product = 'Cleaned Maize'), 0)
    INTO v_available;

  IF NEW.maize_kg > v_available THEN
    RAISE EXCEPTION
      'Not enough cleaned maize at Main: % kg available, % kg requested',
      v_available, NEW.maize_kg
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


-- ── Sales may not exceed stock ───────────────────────────────
CREATE OR REPLACE FUNCTION public.check_sale_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || NEW.branch));

  IF NEW.product = 'Flour' THEN
    RAISE EXCEPTION
      'Flour is no longer a sold product. Use Semoule or Ordinaire.'
      USING ERRCODE = 'check_violation';
  END IF;

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

  -- Bulk: Bran and Cleaned Maize, Main only.
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


-- ── A dispatch may not send sacks Main does not have ─────────
CREATE OR REPLACE FUNCTION public.check_transfer_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_Main'));

  v_available := public.sacks_in_stock('Main', NEW.product, NEW.size_kg);

  IF NEW.sacks_sent > v_available THEN
    RAISE EXCEPTION
      'Not enough % % kg sacks at Main: % in stock, % being sent',
      NEW.product, NEW.size_kg, v_available, NEW.sacks_sent
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


-- ── Rusizi cannot confirm receiving more than was sent ───────
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_received_lte_sent;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_received_lte_sent
  CHECK (sacks_received IS NULL OR sacks_received <= sacks_sent);


-- ============================================================
-- STEP 10: ATOMIC PRODUCTION (rewritten for the new model)
-- ============================================================
-- Yield rules live here, not in the browser, so a tampered client
-- cannot book 100kg of maize as 100kg of semoule plus 32kg of bran.
--
--   Semoule:   output = maize × rate,  bran = maize − output
--   Ordinaire: output = maize,         bran = 0
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_production(
  p_product_type    TEXT,
  p_maize_kg        INTEGER,
  p_processing_rate NUMERIC,     -- NULL for Ordinaire
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
    'Main', p_production_time, auth.uid()
  )
  RETURNING * INTO v_production;

  -- Sacks: only sizes valid for this product, only non-zero counts.
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

  -- Packing more than was milled would create stock out of nothing.
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
  TEXT, INTEGER, NUMERIC, TIMESTAMPTZ, JSONB
) TO authenticated;


-- ============================================================
-- DONE
-- ============================================================
-- Verify:
--   SELECT 'Main' AS branch, * FROM public.branch_stock('Main')
--   UNION ALL
--   SELECT 'Rusizi', * FROM public.branch_stock('Rusizi')
--   ORDER BY 1, 2, 3;
--
-- Then re-check the converted production rows, which were inferred
-- rather than recorded:
--   SELECT id, production_time, product_type, maize_kg,
--          processing_rate, output_kg, bran_kg
--     FROM public.productions ORDER BY production_time DESC;
-- ============================================================
