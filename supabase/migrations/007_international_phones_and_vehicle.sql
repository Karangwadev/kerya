-- ============================================================
-- KERYA MAIZE — Migration 007: International Phones & Vehicle
-- Run in: Supabase Dashboard → SQL Editor, AFTER 006.
--
-- Two corrections:
--
--   1. 006 only accepted Rwandan mobiles. Rusizi is on the DRC
--      border, so a customer with a Congolese, Burundian or any
--      other foreign number is ordinary business, not an error.
--
--      The rule is now: a number written with a leading + is taken
--      as international and checked only for plausible length
--      (E.164 allows up to 15 digits). A number written WITHOUT a +
--      is local shorthand and must be a Rwandan mobile — because
--      that is the only country whose shorthand we can interpret.
--
--   2. Transfers can record the truck's plate. Optional: stock
--      sometimes moves without one being noted, and a blocked form
--      would only push staff into inventing a plate.
--
-- Safe to re-run.
-- ============================================================


-- ============================================================
-- STEP 1: ACCEPT INTERNATIONAL NUMBERS
-- ============================================================

ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_phone_format;
ALTER TABLE public.purchases ADD  CONSTRAINT purchases_phone_format
  CHECK (
    phone IS NULL
    -- Written with a country code: trust it, check only the length.
    OR (phone LIKE '+%'
        AND regexp_replace(phone, '[^0-9]', '', 'g') ~ '^[0-9]{8,15}$')
    -- Written as local shorthand: must be a Rwandan mobile.
    OR regexp_replace(phone, '[^0-9]', '', 'g') ~ '^(250)?0?7[0-9]{8}$'
  );

ALTER TABLE public.sales DROP CONSTRAINT IF EXISTS sales_phone_format;
ALTER TABLE public.sales ADD  CONSTRAINT sales_phone_format
  CHECK (
    (phone LIKE '+%'
     AND regexp_replace(phone, '[^0-9]', '', 'g') ~ '^[0-9]{8,15}$')
    OR regexp_replace(phone, '[^0-9]', '', 'g') ~ '^(250)?0?7[0-9]{8}$'
  );


-- ============================================================
-- STEP 2: VEHICLE PLATE ON TRANSFERS
-- ============================================================
-- Optional by design. The existing `note` field stays for anything
-- else (driver, reference); the plate gets its own column so it can
-- be searched and shown in its own table column.

ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS vehicle_plate TEXT;

-- Deliberately NOT a Rwandan plate pattern. Trucks crossing from the
-- DRC carry Congolese plates, and refusing those would be the same
-- mistake as refusing foreign phone numbers. Only shape is checked.
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_plate_shape;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_plate_shape
  CHECK (
    vehicle_plate IS NULL
    OR (length(trim(vehicle_plate)) BETWEEN 2 AND 15
        AND vehicle_plate ~ '^[A-Z0-9][A-Z0-9 /-]*$')
  );

UPDATE public.transfers SET vehicle_plate = NULL
 WHERE trim(COALESCE(vehicle_plate,'')) = '';

COMMENT ON COLUMN public.transfers.vehicle_plate IS
  'Optional. Uppercase; any country''s format. NULL means none recorded.';

CREATE INDEX IF NOT EXISTS idx_transfers_plate
  ON public.transfers (vehicle_plate) WHERE vehicle_plate IS NOT NULL;


-- ============================================================
-- STEP 3: THE PLATE IS THE SENDER'S RECORD
-- ============================================================
-- guard_transfer_update pins what the dispatching branch recorded so
-- the receiving branch cannot rewrite it. The plate belongs in that
-- list — the receiver confirms how many sacks arrived, not which
-- lorry they left on.

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
    NEW.vehicle_plate := OLD.vehicle_plate;
    NEW.dispatched_at := OLD.dispatched_at;
    NEW.dispatched_by := OLD.dispatched_by;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================
-- DONE
-- ============================================================
-- Check:
--   SELECT dispatched_at, from_branch, to_branch, product,
--          sacks_sent, vehicle_plate, note
--     FROM public.transfers ORDER BY dispatched_at DESC;
-- ============================================================
