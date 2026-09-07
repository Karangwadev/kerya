-- ============================================================
-- KERYA MAIZE — Migration 009: Multi-Item Dispatches
-- Run in: Supabase Dashboard → SQL Editor, AFTER 008.
--
-- Until now a transfer was one product, one sack size, one count.
-- A lorry carrying 30 × 25kg Semoule, 20 × 50kg Ordinaire and 40 ×
-- 5kg Semoule had to be entered as three separate transfers, each
-- confirmed separately, with the plate retyped each time. The stock
-- arithmetic was right, but the record did not say that one truck
-- made one trip.
--
-- A dispatch is now a delivery note:
--
--   transfers       the trip   — from, to, plate, note, date, status
--   transfer_items  the load   — one line per product + sack size
--
-- The receiving branch opens one dispatch and confirms line by line,
-- so a shortfall is recorded against the line it happened on.
--
-- Each dispatch gets a reference (TRF-0001) so staff can refer to it
-- by name on the phone.
--
-- >>> RUN THIS FILE ONCE. <<< It moves columns off `transfers` and
-- then drops them, so a second run fails on the missing column.
-- ============================================================


-- ============================================================
-- STEP 1: THE LINES TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.transfer_items (
  id             UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id    UUID    NOT NULL REFERENCES public.transfers(id) ON DELETE CASCADE,
  product        TEXT    NOT NULL,
  size_kg        INTEGER NOT NULL,
  sacks_sent     INTEGER NOT NULL CHECK (sacks_sent > 0),
  sacks_received INTEGER          CHECK (sacks_received >= 0),

  FOREIGN KEY (product, size_kg) REFERENCES public.sack_sizes (product, size_kg),

  -- One line per product+size on a dispatch: two lines for the same
  -- thing would just be one line with a bigger number.
  UNIQUE (transfer_id, product, size_kg),

  CONSTRAINT transfer_items_received_lte_sent
    CHECK (sacks_received IS NULL OR sacks_received <= sacks_sent)
);

CREATE INDEX IF NOT EXISTS idx_transfer_items_transfer ON public.transfer_items (transfer_id);
CREATE INDEX IF NOT EXISTS idx_transfer_items_product  ON public.transfer_items (product, size_kg);

ALTER TABLE public.transfer_items ENABLE ROW LEVEL SECURITY;

-- Visibility follows the parent dispatch.
DROP POLICY IF EXISTS "transfer_items_select" ON public.transfer_items;
CREATE POLICY "transfer_items_select"
  ON public.transfer_items FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "transfer_items_insert" ON public.transfer_items;
CREATE POLICY "transfer_items_insert"
  ON public.transfer_items FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.transfers t
       WHERE t.id = transfer_id
         AND (get_my_role() IN ('admin','manager')
              OR (get_my_role() = 'staff' AND t.from_branch = get_my_branch()))
    )
  );

DROP POLICY IF EXISTS "transfer_items_update" ON public.transfer_items;
CREATE POLICY "transfer_items_update"
  ON public.transfer_items FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM public.transfers t
       WHERE t.id = transfer_id
         AND (get_my_role() IN ('admin','manager')
              OR (get_my_role() = 'staff' AND t.to_branch = get_my_branch()))
    )
  );

-- No DELETE policy: lines go when their dispatch does, via CASCADE
-- through admin_delete_record().


-- ============================================================
-- STEP 2: MOVE EXISTING TRANSFERS ONTO THE NEW SHAPE
-- ============================================================
-- Every existing transfer becomes a dispatch with exactly one line.

INSERT INTO public.transfer_items (transfer_id, product, size_kg, sacks_sent, sacks_received)
SELECT id, product, size_kg, sacks_sent, sacks_received
  FROM public.transfers
 WHERE NOT EXISTS (SELECT 1 FROM public.transfer_items i WHERE i.transfer_id = transfers.id);

-- Constraints that belong to the line, not the trip.
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_received_lte_sent;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_status_rules;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_product_check;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_sacks_sent_check;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_sacks_received_check;
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_product_size_kg_fkey;

DROP INDEX IF EXISTS idx_transfers_product;

ALTER TABLE public.transfers
  DROP COLUMN IF EXISTS product,
  DROP COLUMN IF EXISTS size_kg,
  DROP COLUMN IF EXISTS sacks_sent,
  DROP COLUMN IF EXISTS sacks_received;

-- A confirmed dispatch must carry a confirmation time; a pending one must not.
ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_status_rules;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_status_rules CHECK (
  (status = 'confirmed' AND confirmed_at IS NOT NULL)
  OR (status IN ('pending','cancelled') AND confirmed_at IS NULL)
);


-- ============================================================
-- STEP 3: A HUMAN REFERENCE
-- ============================================================
-- So a dispatch can be named on the phone rather than described.

CREATE SEQUENCE IF NOT EXISTS public.transfer_ref_seq START 1;

ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS reference TEXT;

UPDATE public.transfers
   SET reference = 'TRF-' || lpad(nextval('public.transfer_ref_seq')::text, 4, '0')
 WHERE reference IS NULL;

ALTER TABLE public.transfers
  ALTER COLUMN reference SET DEFAULT 'TRF-' || lpad(nextval('public.transfer_ref_seq')::text, 4, '0');

ALTER TABLE public.transfers DROP CONSTRAINT IF EXISTS transfers_reference_key;
ALTER TABLE public.transfers ADD  CONSTRAINT transfers_reference_key UNIQUE (reference);
ALTER TABLE public.transfers ALTER COLUMN reference SET NOT NULL;


-- ============================================================
-- STEP 4: STOCK, SUMMED OVER LINES
-- ============================================================
-- Same rules as before; the sent/received figures now come from the
-- lines rather than the trip.

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
      + COALESCE((SELECT SUM(ti.sacks_received)
                    FROM transfer_items ti
                    JOIN transfers t ON t.id = ti.transfer_id
                   WHERE ti.product = z.product AND ti.size_kg = z.size_kg
                     AND t.to_branch = p_branch AND t.status = 'confirmed'), 0)
      - COALESCE((SELECT SUM(ti.sacks_sent)
                    FROM transfer_items ti
                    JOIN transfers t ON t.id = ti.transfer_id
                   WHERE ti.product = z.product AND ti.size_kg = z.size_kg
                     AND t.from_branch = p_branch AND t.status <> 'cancelled'), 0)
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
-- STEP 5: DISPATCH IN ONE TRANSACTION
-- ============================================================
-- Header and every line together, so a half-written delivery note
-- cannot exist. Stock is checked for the WHOLE load at once: sending
-- 30 and then 30 more of the same sack when only 50 are held must
-- fail, and would not if each line were checked on its own.

DROP TRIGGER  IF EXISTS trg_check_transfer_stock ON public.transfers;
DROP FUNCTION IF EXISTS public.check_transfer_stock();

CREATE OR REPLACE FUNCTION public.create_transfer(
  p_from_branch   TEXT,
  p_to_branch     TEXT,
  p_plate         TEXT,
  p_note          TEXT,
  p_dispatched_at TIMESTAMPTZ,
  p_items         JSONB   -- [{"product":"Semoule","size_kg":25,"sacks":30}, ...]
)
RETURNS public.transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transfer public.transfers;
  v_product  TEXT;
  v_size     INTEGER;
  v_have     BIGINT;
  v_wanted   BIGINT;
BEGIN
  IF get_my_role() NOT IN ('admin','manager')
     AND NOT (get_my_role() = 'staff' AND p_from_branch = get_my_branch()) THEN
    RAISE EXCEPTION 'You can only dispatch from your own branch';
  END IF;

  IF p_from_branch = p_to_branch THEN
    RAISE EXCEPTION 'A branch cannot transfer stock to itself';
  END IF;
  IF NOT branch_is_active(p_from_branch) THEN
    RAISE EXCEPTION '% is not an active branch', p_from_branch;
  END IF;
  IF NOT branch_is_active(p_to_branch) THEN
    RAISE EXCEPTION '% is not an active branch', p_to_branch;
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'A dispatch needs at least one line';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('kerya_stock_' || p_from_branch));

  -- Stock is checked BEFORE anything is written, and on the TOTAL per
  -- sack size. Two lines of 40 against 70 in stock is 80 requested, and
  -- must fail — checking each line alone would let it through. Checking
  -- first also means the message reports real stock, rather than stock
  -- with this dispatch already deducted from it.
  FOR v_product, v_size, v_wanted IN
    SELECT item ->> 'product',
           (item ->> 'size_kg')::INTEGER,
           SUM((item ->> 'sacks')::INTEGER)
      FROM jsonb_array_elements(p_items) AS item
     WHERE COALESCE((item ->> 'sacks')::INTEGER, 0) > 0
     GROUP BY 1, 2
  LOOP
    v_have := public.sacks_in_stock(p_from_branch, v_product, v_size);
    IF v_wanted > v_have THEN
      RAISE EXCEPTION
        'Not enough % % kg sacks at %: % in stock, % being sent',
        v_product, v_size, p_from_branch, v_have, v_wanted
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  INSERT INTO public.transfers
    (from_branch, to_branch, vehicle_plate, note, status, dispatched_at, dispatched_by)
  VALUES
    (p_from_branch, p_to_branch, NULLIF(trim(COALESCE(p_plate,'')),''),
     NULLIF(trim(COALESCE(p_note,'')),''), 'pending', p_dispatched_at, auth.uid())
  RETURNING * INTO v_transfer;

  -- The SAME aggregate the check used, so what was validated is exactly
  -- what gets written. Naming a product and size twice on one note is
  -- one line with a bigger number, not two lines — and summing it here
  -- rather than relying on ON CONFLICT keeps check and record identical.
  INSERT INTO public.transfer_items (transfer_id, product, size_kg, sacks_sent)
  SELECT v_transfer.id,
         item ->> 'product',
         (item ->> 'size_kg')::INTEGER,
         SUM((item ->> 'sacks')::INTEGER)
    FROM jsonb_array_elements(p_items) AS item
   WHERE COALESCE((item ->> 'sacks')::INTEGER, 0) > 0
   GROUP BY 1, 2, 3;

  IF NOT EXISTS (SELECT 1 FROM public.transfer_items WHERE transfer_id = v_transfer.id) THEN
    RAISE EXCEPTION 'A dispatch needs at least one line with sacks on it';
  END IF;

  RETURN v_transfer;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_transfer(
  TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, JSONB
) TO authenticated;


-- ============================================================
-- STEP 6: CONFIRM THE WHOLE NOTE AT ONCE
-- ============================================================
-- The receiving branch counts each line and confirms once. A line
-- left out is taken as nothing arrived on it, rather than silently
-- treated as complete.

CREATE OR REPLACE FUNCTION public.confirm_transfer(
  p_transfer_id UUID,
  p_received    JSONB   -- [{"item_id":"…","sacks":28}, ...]
)
RETURNS public.transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transfer public.transfers;
  v_row      JSONB;
BEGIN
  SELECT * INTO v_transfer FROM public.transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch not found'; END IF;

  IF v_transfer.status = 'confirmed' AND get_my_role() <> 'admin' THEN
    RAISE EXCEPTION 'This dispatch is already confirmed. Ask an admin to correct it.';
  END IF;

  IF get_my_role() NOT IN ('admin','manager')
     AND NOT (get_my_role() = 'staff' AND v_transfer.to_branch = get_my_branch()) THEN
    RAISE EXCEPTION 'Only % can confirm this dispatch', v_transfer.to_branch;
  END IF;

  -- Anything not mentioned arrived as zero, not as "all of it".
  UPDATE public.transfer_items SET sacks_received = 0 WHERE transfer_id = p_transfer_id;

  FOR v_row IN SELECT * FROM jsonb_array_elements(COALESCE(p_received,'[]'::jsonb)) LOOP
    UPDATE public.transfer_items
       SET sacks_received = (v_row ->> 'sacks')::INTEGER
     WHERE id = (v_row ->> 'item_id')::UUID
       AND transfer_id = p_transfer_id;
  END LOOP;

  UPDATE public.transfers
     SET status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid()
   WHERE id = p_transfer_id
  RETURNING * INTO v_transfer;

  RETURN v_transfer;
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_transfer(UUID, JSONB) TO authenticated;


-- ============================================================
-- STEP 7: GUARD, DELETE AND STOCK SAFETY UPDATED
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_transfer_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status = 'confirmed' AND get_my_role() <> 'admin' THEN
    RAISE EXCEPTION 'This dispatch is already confirmed. Ask an admin to correct it.';
  END IF;

  -- The trip is the sender's record; the receiver reports arrivals only.
  IF get_my_role() NOT IN ('admin', 'manager') THEN
    NEW.reference     := OLD.reference;
    NEW.from_branch   := OLD.from_branch;
    NEW.to_branch     := OLD.to_branch;
    NEW.vehicle_plate := OLD.vehicle_plate;
    NEW.dispatched_at := OLD.dispatched_at;
    NEW.dispatched_by := OLD.dispatched_by;
  END IF;

  RETURN NEW;
END;
$$;

-- The receiving branch may report what arrived, never rewrite what was sent.
CREATE OR REPLACE FUNCTION public.guard_transfer_item_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF get_my_role() NOT IN ('admin', 'manager') THEN
    NEW.product    := OLD.product;
    NEW.size_kg    := OLD.size_kg;
    NEW.sacks_sent := OLD.sacks_sent;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_transfer_item_update ON public.transfer_items;
CREATE TRIGGER trg_guard_transfer_item_update
  BEFORE UPDATE ON public.transfer_items
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_transfer_item_update();


-- admin_delete_record's transfer branch described a single line.
CREATE OR REPLACE FUNCTION public.admin_delete_record(
  p_entity TEXT,
  p_id     UUID,
  p_reason TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_snapshot JSONB;
  v_summary  TEXT;
  v_branch   TEXT;
BEGIN
  IF get_my_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can delete records';
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'A reason is required so the deletion can be understood later';
  END IF;

  IF p_entity = 'purchase' THEN
    SELECT to_jsonb(p), p.branch,
           format('%s kg cleaned maize from %s, RWF %s, %s',
                  p.final_qty_kg, COALESCE(p.supplier, 'unnamed supplier'),
                  p.total_rwf, to_char(p.entry_time, 'DD Mon YYYY'))
      INTO v_snapshot, v_branch, v_summary
      FROM public.purchases p WHERE p.id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;
    DELETE FROM public.purchases WHERE id = p_id;

  ELSIF p_entity = 'production' THEN
    SELECT to_jsonb(pr), pr.branch,
           format('%s kg maize → %s kg %s, %s',
                  pr.maize_kg, pr.output_kg, pr.product_type,
                  to_char(pr.production_time, 'DD Mon YYYY'))
      INTO v_snapshot, v_branch, v_summary
      FROM public.productions pr WHERE pr.id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Production not found'; END IF;
    DELETE FROM public.productions WHERE id = p_id;

  ELSIF p_entity = 'sale' THEN
    SELECT to_jsonb(s), s.branch,
           format('%s to %s, RWF %s, %s',
                  CASE WHEN s.sack_count IS NULL
                       THEN s.qty_kg || ' kg ' || s.product
                       ELSE s.sack_count || ' × ' || s.size_kg || 'kg ' || s.product END,
                  COALESCE(s.customer, 'unnamed customer'),
                  s.total_rwf, to_char(s.sale_time, 'DD Mon YYYY'))
      INTO v_snapshot, v_branch, v_summary
      FROM public.sales s WHERE s.id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found'; END IF;
    DELETE FROM public.sales WHERE id = p_id;

  ELSIF p_entity = 'transfer' THEN
    -- The snapshot carries the whole delivery note, lines included,
    -- because the lines cascade away with it.
    SELECT to_jsonb(t) || jsonb_build_object(
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(i))
                                  FROM public.transfer_items i
                                 WHERE i.transfer_id = t.id), '[]'::jsonb)),
           t.from_branch,
           format('%s: %s, %s → %s (%s)',
                  t.reference,
                  COALESCE((SELECT string_agg(i.sacks_sent || ' × ' || i.size_kg || 'kg ' || i.product, ', '
                                              ORDER BY i.product, i.size_kg DESC)
                              FROM public.transfer_items i WHERE i.transfer_id = t.id),
                           'no lines'),
                  t.from_branch, t.to_branch, t.status)
      INTO v_snapshot, v_branch, v_summary
      FROM public.transfers t WHERE t.id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch not found'; END IF;
    DELETE FROM public.transfers WHERE id = p_id;

  ELSE
    RAISE EXCEPTION 'Cannot delete "%" records', p_entity;
  END IF;

  PERFORM public.assert_stock_not_negative();

  INSERT INTO public.activity_log
    (action, details, branch, performed_by, severity, entity, entity_id, snapshot)
  VALUES (
    'Record deleted: ' || p_entity,
    v_summary || ' — reason: ' || trim(p_reason),
    v_branch, auth.uid(), 'critical', p_entity, p_id, v_snapshot
  );

  RETURN v_summary;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_record(TEXT, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_record(TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- DONE
-- ============================================================
-- A dispatch and its load:
--   SELECT t.reference, t.from_branch, t.to_branch, t.vehicle_plate,
--          t.status, i.product, i.size_kg, i.sacks_sent, i.sacks_received
--     FROM public.transfers t
--     JOIN public.transfer_items i ON i.transfer_id = t.id
--    ORDER BY t.dispatched_at DESC, i.product, i.size_kg DESC;
-- ============================================================
