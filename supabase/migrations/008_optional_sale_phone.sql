-- ============================================================
-- KERYA MAIZE — Migration 008: Sale Phone Becomes Optional
-- Run in: Supabase Dashboard → SQL Editor, AFTER 007.
--
-- 006 made the supplier's phone optional but kept the customer's
-- required, on the assumption that we always have a number for a
-- buyer. That is not so — a walk-in customer paying cash may not
-- leave one, and a mandatory field only pushes staff into typing a
-- placeholder, which is worse than an honest blank.
--
-- Both sides are now optional. Where a number IS given it must still
-- be plausible: Rwandan shorthand, or any international number
-- written with its country code (007).
--
-- Safe to re-run.
-- ============================================================


-- ============================================================
-- STEP 1: DROP THE REQUIREMENT
-- ============================================================

ALTER TABLE public.sales ALTER COLUMN phone DROP NOT NULL;

-- "No phone given" gets one representation, not two.
UPDATE public.sales SET phone = NULL WHERE trim(COALESCE(phone,'')) = '';

-- 006 required a non-blank string. That is now covered by the NULL
-- rule plus the format check below, so the standalone constraint goes.
ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_phone_not_blank;

COMMENT ON COLUMN public.sales.phone IS
  'Optional — a walk-in customer may not leave a number. NULL means none given.';


-- ============================================================
-- STEP 2: FORMAT CHECK NOW TOLERATES NULL
-- ============================================================
-- Same rule as purchases: a leading + means international and is
-- checked for length only; without a + it must be a Rwandan mobile,
-- because that is the only shorthand we can interpret.

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_phone_format;
ALTER TABLE public.sales ADD  CONSTRAINT sales_phone_format
  CHECK (
    phone IS NULL
    OR (phone LIKE '+%'
        AND regexp_replace(phone, '[^0-9]', '', 'g') ~ '^[0-9]{8,15}$')
    OR regexp_replace(phone, '[^0-9]', '', 'g') ~ '^(250)?0?7[0-9]{8}$'
  );


-- ============================================================
-- DONE
-- ============================================================
-- Both should now read YES:
--   SELECT table_name, is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND column_name='phone'
--      AND table_name IN ('purchases','sales');
-- ============================================================
