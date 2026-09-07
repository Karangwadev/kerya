-- ============================================================
-- KERYA MAIZE — Migration 005: Password Management
-- Run in: Supabase Dashboard → SQL Editor, AFTER 004.
--
-- Passwords live in Supabase Auth (auth.users), not in this schema,
-- and changing someone else's requires the service_role key — which
-- must never reach a browser. So the actual reset is done by an Edge
-- Function (supabase/functions/admin-reset-password).
--
-- This migration adds the parts that DO belong in the database:
--
--   * must_change_password — set when an admin resets someone's
--     password, cleared when that person chooses their own. An admin
--     therefore never keeps working knowledge of a live password.
--   * An audit entry for every reset.
--
-- Users can always change their OWN password without any of this —
-- that goes straight through Supabase Auth with their own session.
-- ============================================================


-- ============================================================
-- STEP 1: THE FLAG
-- ============================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS password_changed_at  TIMESTAMPTZ;

COMMENT ON COLUMN public.profiles.must_change_password IS
  'Set when an admin resets this password. The user must choose a new one before using the system.';


-- ============================================================
-- STEP 2: KEEP THE FLAG OUT OF THE PINNED COLUMNS
-- ============================================================
-- guard_profile_update() pins role, branch, active and username for
-- non-admins. must_change_password must stay writable by the user
-- themselves — clearing it is the last step of choosing a password.
-- Rewritten in full so the pinned list is unambiguous.

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
    IF (NEW.role = 'admin' OR OLD.role = 'admin')
       AND NEW.role IS DISTINCT FROM OLD.role
       AND v_actor_role <> 'admin' THEN
      RAISE EXCEPTION 'Only an admin can grant or revoke the admin role';
    END IF;

    IF OLD.role = 'admin' AND v_actor_role <> 'admin' THEN
      RAISE EXCEPTION 'Only an admin can modify an admin account';
    END IF;

    IF NEW.id = auth.uid() AND OLD.active AND NOT NEW.active THEN
      RAISE EXCEPTION 'You cannot deactivate your own account';
    END IF;

    RETURN NEW;
  END IF;

  -- staff / stakeholder: privilege columns pinned to their previous
  -- values. They may edit their display name, and clear their own
  -- must_change_password flag once they have set a new password.
  NEW.role     := OLD.role;
  NEW.branch   := OLD.branch;
  NEW.active   := OLD.active;
  NEW.username := OLD.username;

  -- Turning the flag OFF is a user action (they just chose a password).
  -- Turning it ON is only ever done by log_password_reset, which marks
  -- itself with a transaction-local setting. Without that marker the
  -- flag is pinned, so nobody can raise it on anyone.
  --
  -- This matters because the Edge Function calls log_password_reset as
  -- service_role, where auth.uid() is NULL and get_my_role() therefore
  -- returns NULL — which lands here, in the non-admin branch.
  IF NEW.must_change_password AND NOT OLD.must_change_password
     AND COALESCE(current_setting('app.password_reset', true), '') <> 'on' THEN
    NEW.must_change_password := OLD.must_change_password;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================
-- STEP 3: RECORD THE RESET
-- ============================================================
-- Called by the Edge Function AFTER it has changed the password, so
-- the audit trail carries every reset. SECURITY DEFINER because the
-- function runs as the service role, which has no profile row and so
-- would fail get_my_role().

CREATE OR REPLACE FUNCTION public.log_password_reset(
  p_target_user UUID,
  p_actor       UUID,
  p_note        TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target   RECORD;
  v_actor_nm TEXT;
BEGIN
  SELECT username, name, branch INTO v_target
    FROM public.profiles WHERE id = p_target_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown user'; END IF;

  SELECT username INTO v_actor_nm FROM public.profiles WHERE id = p_actor;

  -- Marks this transaction as the legitimate reset path so
  -- guard_profile_update permits the flag to be raised. Transaction-local
  -- (the `true` argument), so it cannot leak into anything else.
  PERFORM set_config('app.password_reset', 'on', true);

  UPDATE public.profiles
     SET must_change_password = true,
         password_changed_at  = now()
   WHERE id = p_target_user;

  INSERT INTO public.activity_log
    (action, details, branch, performed_by, severity, entity, entity_id)
  VALUES (
    'Password reset by admin',
    format('%s (%s) — reset by %s. They must choose a new password at next sign-in.%s',
           v_target.name, v_target.username,
           COALESCE(v_actor_nm, 'unknown'),
           CASE WHEN p_note IS NULL OR trim(p_note) = '' THEN '' ELSE ' Note: ' || trim(p_note) END),
    v_target.branch, p_actor, 'critical', 'profile', p_target_user
  );
END;
$$;

REVOKE ALL ON FUNCTION public.log_password_reset(UUID, UUID, TEXT) FROM PUBLIC;
-- Only the service role (the Edge Function) calls this.
GRANT EXECUTE ON FUNCTION public.log_password_reset(UUID, UUID, TEXT) TO service_role;


-- ============================================================
-- STEP 4: SELF-SERVICE PASSWORD CHANGE
-- ============================================================
-- The password change itself happens through Supabase Auth with the
-- user's own session. This just records that it happened and clears
-- the forced-change flag, in one place so the client cannot clear the
-- flag without the log entry.

CREATE OR REPLACE FUNCTION public.confirm_own_password_change()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me RECORD;
BEGIN
  SELECT username, name, branch INTO v_me
    FROM public.profiles WHERE id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Not signed in'; END IF;

  UPDATE public.profiles
     SET must_change_password = false,
         password_changed_at  = now()
   WHERE id = auth.uid();

  INSERT INTO public.activity_log
    (action, details, branch, performed_by, severity, entity, entity_id)
  VALUES (
    'Password changed',
    format('%s (%s) changed their own password', v_me.name, v_me.username),
    v_me.branch, auth.uid(), 'warning', 'profile', auth.uid()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_own_password_change() TO authenticated;


-- ============================================================
-- DONE
-- ============================================================
-- The Edge Function still has to be deployed — see
-- supabase/functions/admin-reset-password/README.md
--
-- Check who is carrying a forced change:
--   SELECT username, role, branch, must_change_password, password_changed_at
--     FROM public.profiles ORDER BY username;
-- ============================================================
