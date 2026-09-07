// ============================================================
// KERYA MAIZE — Supabase Client
// Loaded as a regular <script> (no type="module" needed).
// Supabase CDN must be loaded BEFORE this file in index.html.
// ============================================================
// Paste your Project URL and anon key from:
//   Supabase Dashboard → Project Settings → API
// ============================================================

const SUPABASE_URL      = 'https://tcdkgnfuxssxevcpttum.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjZGtnbmZ1eHNzeGV2Y3B0dHVtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2MTIxMzgsImV4cCI6MjA4OTE4ODEzOH0.5VZjeV77bIRShFVoEgHXQHC1gFnHgBpEJYU05--cUmQ';

// window.supabase is provided by the CDN script
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Expose globally so auth.js and db.js can use it
window.supabaseClient = supabaseClient;
