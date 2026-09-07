// ============================================================
// KERYA MAIZE — Edge Function: admin-reset-password
//
// Changing another user's password requires the service_role key.
// That key must NEVER reach a browser, so it lives here instead:
// Supabase injects it as an environment variable and this function
// runs on Supabase's servers, not the user's machine.
//
// What it does, in order:
//   1. Reads the caller's own JWT from the Authorization header.
//   2. Confirms that caller is a real, ACTIVE admin — by looking up
//      their profile, not by trusting anything the request says.
//   3. Refuses obviously weak passwords.
//   4. Changes the target user's password via the Auth admin API.
//   5. Flags the target as must_change_password and writes an audit
//      entry, so the admin never keeps working knowledge of a live
//      password and the reset is on the record.
//
// Deploy:  supabase functions deploy admin-reset-password
// See README.md in this folder for the full walkthrough.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST')    return reply({ error: 'Use POST' }, 405);

  try {
    const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
    const SERVICE_ROLE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const ANON_KEY          = Deno.env.get('SUPABASE_ANON_KEY')!;

    // ── 1. Who is calling? ──────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    if (!authHeader.startsWith('Bearer ')) {
      return reply({ error: 'Not signed in' }, 401);
    }

    // A client bound to the CALLER's token, so auth.getUser() returns
    // them and not the service role.
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user: caller }, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !caller) return reply({ error: 'Not signed in' }, 401);

    // ── 2. Are they actually an admin? ──────────────────────
    // Checked against the database. The request body has no say in this.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: callerProfile } = await admin
      .from('profiles')
      .select('role, active, username')
      .eq('id', caller.id)
      .single();

    if (!callerProfile || callerProfile.role !== 'admin' || !callerProfile.active) {
      return reply({ error: 'Only an active admin can reset passwords' }, 403);
    }

    // ── 3. Validate the request ─────────────────────────────
    const { userId, newPassword, note } = await req.json().catch(() => ({}));

    if (!userId || typeof userId !== 'string') {
      return reply({ error: 'Which user?' }, 400);
    }
    if (typeof newPassword !== 'string' || newPassword.length < 8) {
      return reply({ error: 'Password must be at least 8 characters' }, 400);
    }
    // Rules out the obvious ones an admin under time pressure reaches for.
    const weak = ['password', '12345678', 'admin123', 'kerya123', 'qwerty123'];
    if (weak.includes(newPassword.toLowerCase())) {
      return reply({ error: 'That password is too easy to guess — choose another' }, 400);
    }

    const { data: targetProfile } = await admin
      .from('profiles')
      .select('username, name')
      .eq('id', userId)
      .single();

    if (!targetProfile) return reply({ error: 'User not found' }, 404);

    // ── 4. Change it ────────────────────────────────────────
    const { error: updateErr } = await admin.auth.admin.updateUserById(userId, {
      password: newPassword,
    });
    if (updateErr) return reply({ error: updateErr.message }, 400);

    // ── 5. Flag + log, so the reset is on the record ────────
    // If this fails the password IS already changed, so report it
    // rather than pretending the whole thing failed.
    const { error: logErr } = await admin.rpc('log_password_reset', {
      p_target_user: userId,
      p_actor:       caller.id,
      p_note:        note ?? null,
    });

    return reply({
      ok: true,
      username: targetProfile.username,
      name: targetProfile.name,
      warning: logErr
        ? 'Password was changed, but the audit entry failed to write: ' + logErr.message
        : undefined,
    });

  } catch (err) {
    return reply({ error: (err as Error).message ?? 'Unexpected error' }, 500);
  }
});
