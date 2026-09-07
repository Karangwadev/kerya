-- ============================================================
-- KERYA MAIZE — Migration 006: Phone Number Rules
-- Run in: Supabase Dashboard → SQL Editor, AFTER 005.
--
-- The two sides of the business are not symmetrical:
--
--   Purchases — a farmer can arrive with maize and no phone. Making
--               the number mandatory would push staff into inventing
--               one, which is worse than having none.
--   Sales     — customers are always reached by phone, so it stays
--               required there.
--
-- Where a number IS given, it must look like a real Rwandan mobile,
-- so a slipped digit is caught at entry rather than discovered when
-- someone tries to ring it.
--
-- Safe to re-run.
-- ============================================================


-- ============================================================
-- STEP 0: EXISTING DATA
-- ============================================================
-- STEP 3 rejects anything that is not a plausible Rwandan mobile. If
-- you have test rows with placeholder numbers, this migration will
-- fail until they are gone. Check what would be refused:
--
--   SELECT 'purchase' AS src, id, phone FROM public.purchases
--    WHERE phone IS NOT NULL
--      AND regexp_replace(phone,'[^0-9]','','g') !~ '^(250)?0?7[0-9]{8}$'
--   UNION ALL
--   SELECT 'sale', id, phone FROM public.sales
--    WHERE regexp_replace(phone,'[^0-9]','','g') !~ '^(250)?0?7[0-9]{8}$';
--
-- Clear test data first if that returns rows (see STATUS.md).
-- ============================================================


-- ============================================================
-- STEP 1: PURCHASES — PHONE BECOMES OPTIONAL
-- ============================================================

ALTER TABLE public.purchases ALTER COLUMN phone DROP NOT NULL;

-- An empty string is not the same as "no phone", and having both
-- would mean two ways to say the same thing. Normalise to NULL.
UPDATE public.purchases SET phone = NULL WHERE trim(COALESCE(phone,'')) = '';

COMMENT ON COLUMN public.purchases.phone IS
  'Optional — a supplier may have no phone. NULL means none given.';


-- ============================================================
-- STEP 2: SALES — PHONE STAYS REQUIRED
-- ============================================================
-- Restated rather than assumed, so the intent is on the record.

ALTER TABLE public.sales ALTER COLUMN phone SET NOT NULL;

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_phone_not_blank;
ALTER TABLE public.sales ADD  CONSTRAINT sales_phone_not_blank
  CHECK (length(trim(phone)) > 0);

COMMENT ON COLUMN public.sales.phone IS
  'Required — customers are always reachable by phone.';


-- ============================================================
-- STEP 3: FORMAT
-- ============================================================
-- Punctuation is stripped before checking, so +250 788 123 456,
-- 0788123456 and 788123456 are all accepted and none of the three
-- has to be typed a particular way. What is enforced is that the
-- digits describe a Rwandan mobile: an optional 250 country code,
-- an optional trunk 0, then 7 followed by eight digits.
--
-- Landlines (025x…) are deliberately NOT accepted. If a supplier or
-- customer ever gives one, widen this to '^(250)?0?(7|2)[0-9]{8}$'.

ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_phone_format;
ALTER TABLE public.purchases ADD  CONSTRAINT purchases_phone_format
  CHECK (
    phone IS NULL
    OR regexp_replace(phone, '[^0-9]', '', 'g') ~ '^(250)?0?7[0-9]{8}$'
  );

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_phone_format;
ALTER TABLE public.sales ADD  CONSTRAINT sales_phone_format
  CHECK (
    regexp_replace(phone, '[^0-9]', '', 'g') ~ '^(250)?0?7[0-9]{8}$'
  );


-- ============================================================
-- DONE
-- ============================================================
-- Check the rules took:
--   SELECT column_name, is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND table_name IN ('purchases','sales')
--      AND column_name='phone';
-- Expect purchases=YES, sales=NO.
-- ============================================================
