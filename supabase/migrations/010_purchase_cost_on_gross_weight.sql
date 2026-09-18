-- ============================================================
-- KERYA MAIZE — Migration 010: Purchase Cost on Gross Weight
-- Run in: Supabase Dashboard → SQL Editor, AFTER 009.
--
-- A supplier is paid for everything delivered, waste included.
-- 2,000 kg at 400 RWF with 100 kg of dirt costs 800,000 — not
-- 760,000. The waste is removed after purchase; it was still bought.
--
-- The app was computing cost as (cleaned kg × price), so every
-- purchase understated its cost by exactly waste × price.
--
-- Worse, nothing in the database checked the figure — the browser
-- decided what a purchase cost. This migration makes the database
-- the authority: total_rwf is computed here, on every insert and
-- update, from the gross weight and the price per kg.
--
-- Existing rows are corrected, and the correction is written to the
-- activity log so the change in historical totals is on the record.
--
-- Safe to re-run.
-- ============================================================


-- ============================================================
-- STEP 1: CORRECT EXISTING PURCHASES, AND SAY SO IN THE LOG
-- ============================================================
-- One log entry per branch, stating how many purchases changed and by
-- how much the total cost moved. Runs before the trigger exists so the
-- figures are the before-and-after of this correction alone.

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT branch,
           count(*)                                        AS n,
           SUM(qty_kg * price_per_unit - total_rwf)::BIGINT AS delta
      FROM public.purchases
     WHERE total_rwf IS DISTINCT FROM qty_kg * price_per_unit
     GROUP BY branch
  LOOP
    INSERT INTO public.activity_log (action, details, branch, severity, entity)
    VALUES (
      'Purchase costs corrected',
      format('%s purchase(s) re-costed on gross weight (waste included). '
          || 'Recorded cost changed by RWF %s.', r.n, r.delta),
      r.branch, 'warning', 'purchase'
    );
  END LOOP;

  UPDATE public.purchases
     SET total_rwf = qty_kg * price_per_unit
   WHERE total_rwf IS DISTINCT FROM qty_kg * price_per_unit;
END $$;


-- ============================================================
-- STEP 2: THE DATABASE COMPUTES THE COST FROM NOW ON
-- ============================================================
-- Whatever the client sends for total_rwf is overwritten. Covers
-- updates too, so an admin correcting a weight or price cannot leave
-- the cost stale.

CREATE OR REPLACE FUNCTION public.compute_purchase_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.total_rwf := NEW.qty_kg * NEW.price_per_unit;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_compute_purchase_total ON public.purchases;
CREATE TRIGGER trg_compute_purchase_total
  BEFORE INSERT OR UPDATE ON public.purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.compute_purchase_total();

-- Belt and braces: states the rule, and would catch it if the trigger
-- were ever dropped.
ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_cost_on_gross;
ALTER TABLE public.purchases ADD  CONSTRAINT purchases_cost_on_gross
  CHECK (total_rwf = qty_kg * price_per_unit);

COMMENT ON COLUMN public.purchases.total_rwf IS
  'Amount paid = qty_kg (gross, waste included) × price_per_unit. Computed by trigger.';
COMMENT ON COLUMN public.purchases.price_per_unit IS
  'Price per kg, paid on the full delivered weight.';


-- ============================================================
-- DONE
-- ============================================================
-- Check — cost per cleaned kg is now higher than the price paid:
--   SELECT supplier, qty_kg, dirt_kg, final_qty_kg, price_per_unit,
--          total_rwf,
--          round(total_rwf::numeric / final_qty_kg, 1) AS cost_per_clean_kg
--     FROM public.purchases ORDER BY entry_time DESC;
-- ============================================================
