-- ============================================================
-- KERYA MAIZE — Migration 004: Admin Deletion & Traceability
-- Run in: Supabase Dashboard → SQL Editor, AFTER 003.
--
-- Two things:
--
--   1. Deleting a record is now an admin-only operation that goes
--      through one function, writes its own audit entry in the same
--      transaction, and refuses any delete that would leave stock
--      negative. Deletion without a trace is no longer possible.
--
--   2. The activity log gains the columns and indexes a real audit
--      trail needs, so an admin can answer "what happened, when,
--      and who did it" from the Logs screen.
--
-- Managers previously had raw DELETE rights on purchases,
-- productions and sales — unlogged, and with nothing stopping a
-- delete that broke the stock arithmetic. That is withdrawn here.
-- ============================================================


-- ============================================================
-- STEP 1: WITHDRAW RAW DELETE RIGHTS
-- ============================================================
-- No role gets a plain DELETE policy any more. Deletion happens
-- only through admin_delete_record(), which is SECURITY DEFINER
-- and does the logging and stock checks itself. Taking the policies
-- away means there is no path that skips them.

DROP POLICY IF EXISTS "purchases_delete_admin_manager"   ON public.purchases;
DROP POLICY IF EXISTS "productions_delete_admin_manager" ON public.productions;
DROP POLICY IF EXISTS "sales_delete_admin_manager"       ON public.sales;
DROP POLICY IF EXISTS "prod_sacks_delete_admin_manager"  ON public.production_sacks;

-- activity_log still has no UPDATE or DELETE policy, for anyone,
-- ever. That is the point of an append-only audit trail.


-- ============================================================
-- STEP 2: RICHER AUDIT ENTRIES
-- ============================================================

ALTER TABLE public.activity_log
  ADD COLUMN IF NOT EXISTS severity    TEXT NOT NULL DEFAULT 'info',
  ADD COLUMN IF NOT EXISTS entity      TEXT,      -- 'purchase', 'sale', …
  ADD COLUMN IF NOT EXISTS entity_id   UUID,      -- kept after the row is gone
  ADD COLUMN IF NOT EXISTS snapshot    JSONB;     -- what the row held when deleted

ALTER TABLE public.activity_log DROP CONSTRAINT IF EXISTS activity_log_severity_check;
ALTER TABLE public.activity_log ADD  CONSTRAINT activity_log_severity_check
  CHECK (severity IN ('info', 'warning', 'critical'));

-- The Logs screen filters on these.
CREATE INDEX IF NOT EXISTS idx_activity_severity ON public.activity_log (severity);
CREATE INDEX IF NOT EXISTS idx_activity_entity   ON public.activity_log (entity, entity_id);

-- Full-text-ish search over action and details without a tsvector:
-- the log is small and this keeps ILIKE '%…%' off a sequential scan.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_activity_action_trgm
  ON public.activity_log USING gin (action gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_activity_details_trgm
  ON public.activity_log USING gin (details gin_trgm_ops);

-- Existing INSERT policies constrain performed_by and branch, and
-- carry over unchanged. Severity defaults to 'info', so ordinary
-- entries written by the app need no change.


-- ============================================================
-- STEP 3: STOCK SAFETY NET
-- ============================================================
-- Raises if ANY branch is left holding a negative quantity. Called
-- after a delete, inside the same transaction, so a delete that
-- would break the arithmetic rolls itself back.

CREATE OR REPLACE FUNCTION public.assert_stock_not_negative()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT b.name AS branch, s.product, s.size_kg, s.sacks, s.kg
      FROM public.branches b, LATERAL public.branch_stock(b.name) s
  LOOP
    IF r.size_kg IS NULL AND r.kg < 0 THEN
      RAISE EXCEPTION
        'That would leave % holding % kg of % — delete the records that consumed it first',
        r.branch, r.kg, r.product
        USING ERRCODE = 'check_violation';
    END IF;

    IF r.size_kg IS NOT NULL AND r.sacks < 0 THEN
      RAISE EXCEPTION
        'That would leave % holding % of the % kg % sacks — delete the records that consumed them first',
        r.branch, r.sacks, r.size_kg, r.product
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
END;
$$;


-- ============================================================
-- STEP 4: THE DELETE FUNCTION
-- ============================================================
-- The only way to remove an operational record.
--
--   * admin only
--   * captures a snapshot of the row BEFORE deleting it, so the log
--     still describes what was removed
--   * requires a reason
--   * logs and deletes in one transaction — if the log write fails
--     the delete is rolled back, so an unlogged delete cannot happen
--   * refuses anything that would leave stock negative
--
-- SECURITY DEFINER because STEP 1 removed the DELETE policies; the
-- role check below is what authorises the operation.

CREATE OR REPLACE FUNCTION public.admin_delete_record(
  p_entity TEXT,     -- 'purchase' | 'production' | 'sale' | 'transfer'
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
    -- production_sacks cascades on the FK
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
    SELECT to_jsonb(t), t.from_branch,
           format('%s × %s kg %s, %s → %s (%s)',
                  t.sacks_sent, t.size_kg, t.product,
                  t.from_branch, t.to_branch, t.status)
      INTO v_snapshot, v_branch, v_summary
      FROM public.transfers t WHERE t.id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
    DELETE FROM public.transfers WHERE id = p_id;

  ELSE
    -- activity_log is deliberately absent: it is append-only.
    RAISE EXCEPTION 'Cannot delete "%" records', p_entity;
  END IF;

  -- Rolls the whole thing back if the numbers would stop adding up.
  PERFORM public.assert_stock_not_negative();

  INSERT INTO public.activity_log
    (action, details, branch, performed_by, severity, entity, entity_id, snapshot)
  VALUES (
    'Record deleted: ' || p_entity,
    v_summary || ' — reason: ' || trim(p_reason),
    v_branch,
    auth.uid(),
    'critical',
    p_entity,
    p_id,
    v_snapshot
  );

  RETURN v_summary;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_record(TEXT, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_record(TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- STEP 5: LOG READING
-- ============================================================
-- One filtered query for the Logs screen, so the browser is not
-- pulling the whole table down to search it.

CREATE OR REPLACE FUNCTION public.search_activity_log(
  p_from     TIMESTAMPTZ DEFAULT NULL,
  p_to       TIMESTAMPTZ DEFAULT NULL,
  p_branch   TEXT        DEFAULT NULL,
  p_severity TEXT        DEFAULT NULL,
  p_user     UUID        DEFAULT NULL,
  p_search   TEXT        DEFAULT NULL,
  p_limit    INTEGER     DEFAULT 200
)
RETURNS TABLE (
  id           UUID,
  action       TEXT,
  details      TEXT,
  branch       TEXT,
  severity     TEXT,
  entity       TEXT,
  entity_id    UUID,
  snapshot     JSONB,
  performed_by UUID,
  actor_name   TEXT,
  actor_username TEXT,
  created_at   TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY INVOKER   -- the caller's RLS on activity_log still applies
SET search_path = public
AS $$
  SELECT a.id, a.action, a.details, a.branch, a.severity, a.entity,
         a.entity_id, a.snapshot, a.performed_by,
         p.name, p.username, a.created_at
    FROM public.activity_log a
    LEFT JOIN public.profiles p ON p.id = a.performed_by
   WHERE (p_from     IS NULL OR a.created_at >= p_from)
     AND (p_to       IS NULL OR a.created_at <  p_to)
     AND (p_branch   IS NULL OR a.branch     =  p_branch)
     AND (p_severity IS NULL OR a.severity   =  p_severity)
     AND (p_user     IS NULL OR a.performed_by = p_user)
     AND (p_search   IS NULL OR a.action ILIKE '%' || p_search || '%'
                             OR a.details ILIKE '%' || p_search || '%')
   ORDER BY a.created_at DESC
   LIMIT LEAST(COALESCE(p_limit, 200), 1000);
$$;

GRANT EXECUTE ON FUNCTION public.search_activity_log(
  TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, UUID, TEXT, INTEGER
) TO authenticated;


-- ============================================================
-- STEP 6: LOG THE THINGS THE APP CANNOT
-- ============================================================
-- Sign-ins happen in Supabase Auth, outside this schema, so the app
-- cannot reliably log them. These triggers record structural changes
-- that would otherwise be invisible in the audit trail.

CREATE OR REPLACE FUNCTION public.log_profile_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (
       NEW.role   IS DISTINCT FROM OLD.role
    OR NEW.branch IS DISTINCT FROM OLD.branch
    OR NEW.active IS DISTINCT FROM OLD.active
  ) THEN
    INSERT INTO public.activity_log
      (action, details, branch, performed_by, severity, entity, entity_id)
    VALUES (
      'User account changed',
      format('%s: role %s → %s, branch %s → %s, %s → %s',
             OLD.username, OLD.role, NEW.role, OLD.branch, NEW.branch,
             CASE WHEN OLD.active THEN 'active' ELSE 'inactive' END,
             CASE WHEN NEW.active THEN 'active' ELSE 'inactive' END),
      NEW.branch, auth.uid(), 'warning', 'profile', NEW.id
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_profile_change ON public.profiles;
CREATE TRIGGER trg_log_profile_change
  AFTER UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.log_profile_change();


CREATE OR REPLACE FUNCTION public.log_branch_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.activity_log
      (action, details, branch, performed_by, severity, entity)
    VALUES ('Branch opened',
            format('%s (%s)', NEW.name,
                   CASE WHEN NEW.can_produce THEN 'production site' ELSE 'sales depot' END),
            NEW.name, auth.uid(), 'warning', 'branch');
  ELSIF NEW.active IS DISTINCT FROM OLD.active
     OR NEW.can_produce IS DISTINCT FROM OLD.can_produce THEN
    INSERT INTO public.activity_log
      (action, details, branch, performed_by, severity, entity)
    VALUES ('Branch changed',
            format('%s: %s, %s', NEW.name,
                   CASE WHEN NEW.active THEN 'open' ELSE 'closed' END,
                   CASE WHEN NEW.can_produce THEN 'production site' ELSE 'sales depot' END),
            NEW.name, auth.uid(), 'warning', 'branch');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_branch_change ON public.branches;
CREATE TRIGGER trg_log_branch_change
  AFTER INSERT OR UPDATE ON public.branches
  FOR EACH ROW
  EXECUTE FUNCTION public.log_branch_change();


-- ============================================================
-- DONE
-- ============================================================
-- Check the trail:
--   SELECT created_at, severity, action, details, branch
--     FROM public.activity_log ORDER BY created_at DESC LIMIT 50;
--
-- Deletions are severity 'critical' and keep a full JSON snapshot
-- of the row in activity_log.snapshot, so a mistaken delete can be
-- reconstructed.
-- ============================================================
