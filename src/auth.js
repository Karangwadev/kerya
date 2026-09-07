// ============================================================
// KERYA MAIZE — Authentication
// Loaded as a regular <script> (no type="module").
// Requires supabaseClient.js to be loaded first.
//
// Replaces: doLogin(), doLogout() in script.js
// Adds:     restoreSession() — call at the end of script.js
//
// Calls these globals from script.js (safe — they exist by
// the time any of these functions are invoked by user action):
//   launchApp(), showLoginScreen(), showToast()
// ============================================================

// ── Shared state ─────────────────────────────────────────────
// currentUser mirrors the old localStorage user object shape.
// Written to window so script.js can read it as-is.
let currentUser = null;

// ── Internal helpers ─────────────────────────────────────────

async function fetchProfile(uid) {
  const { data, error } = await window.supabaseClient
    .from('profiles')
    .select('*')
    .eq('id', uid)
    .single();
  if (error) { console.error('fetchProfile:', error.message); return null; }
  return data;
}

function shapeProfile(row) {
  return {
    id:        row.id,
    name:      row.name,
    username:  row.username,
    role:      row.role,
    branch:    row.branch,
    active:    row.active,
    createdAt: row.created_at,
    // Set when an admin resets this password. launchApp() diverts to
    // the forced-change screen while it is true, so an admin-set
    // password cannot go on being used.
    mustChangePassword: row.must_change_password === true,
  };
}

// ── Public API ────────────────────────────────────────────────

/**
 * loginUser(username, password)
 * Called by the login button instead of old doLogin().
 * Maps username → email (username@kerya.com).
 */
async function loginUser(username, password) {
  const email = username.trim().toLowerCase() + '@kerya.com';

  const { data: authData, error: authError } =
    await window.supabaseClient.auth.signInWithPassword({ email, password });

  if (authError) {
    document.getElementById('loginError').style.display = 'block';
    document.getElementById('loginError').textContent = '⚠ ' + authError.message;
    return;
  }

  const profile = await fetchProfile(authData.user.id);

  if (!profile) {
    await window.supabaseClient.auth.signOut();
    document.getElementById('loginError').style.display = 'block';
    document.getElementById('loginError').textContent = '⚠ Account not found. Contact your administrator.';
    return;
  }

  if (!profile.active) {
    await window.supabaseClient.auth.signOut();
    document.getElementById('loginError').style.display = 'block';
    document.getElementById('loginError').textContent = '⚠ Your account is deactivated.';
    return;
  }

  currentUser = shapeProfile(profile);
  window.currentUser = currentUser;
  document.getElementById('loginError').style.display = 'none';
  launchApp();
}

/**
 * logoutUser()
 * Called instead of old doLogout().
 */
async function logoutUser() {
  // Destroy charts (same as old doLogout)
  if (typeof chartInstances !== 'undefined') {
    Object.values(chartInstances).forEach(c => c && c.destroy());
    Object.keys(chartInstances).forEach(k => chartInstances[k] = null);
  }

  await window.supabaseClient.auth.signOut();
  currentUser = null;
  window.currentUser = null;

  document.getElementById('appShell').style.display = 'none';
  document.getElementById('loginScreen').style.display = 'flex';
  // Clears the .admin-only table columns along with the session.
  document.body.classList.remove('is-admin');
  showToast('Signed out successfully', 'info');
}

/**
 * restoreSession()
 * Call once at the end of script.js (replaces the old commented-out
 * auto-login code at the bottom of script.js).
 * If a valid Supabase session exists, skips the login screen.
 */
async function restoreSession() {
  const { data: { session } } = await window.supabaseClient.auth.getSession();

  if (!session) return; // no session → stay on login screen

  const profile = await fetchProfile(session.user.id);

  if (!profile || !profile.active) {
    await window.supabaseClient.auth.signOut();
    return;
  }

  currentUser = shapeProfile(profile);
  window.currentUser = currentUser;
  launchApp();
}

// ── Auth state change listener ────────────────────────────────
window.supabaseClient.auth.onAuthStateChange((event, session) => {
  if (event === 'TOKEN_REFRESHED') {
    console.log('[Auth] Token refreshed silently');
  }
  if (event === 'SIGNED_OUT') {
    currentUser = null;
    window.currentUser = null;
    document.getElementById('appShell').style.display = 'none';
    document.getElementById('loginScreen').style.display = 'flex';
  }
});

// ── Expose on window ──────────────────────────────────────────
window.loginUser      = loginUser;
window.logoutUser     = logoutUser;
window.restoreSession = restoreSession;
