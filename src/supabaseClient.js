// ============================================================
// KERYA MAIZE — Supabase Client
// Loaded as a regular <script> (no type="module" needed).
// Supabase CDN must be loaded BEFORE this file in index.html.
// ============================================================
// Paste your Project URL and anon key from:
//   Supabase Dashboard → Project Settings → API
// ============================================================

const SUPABASE_URL      = 'https://haqlwuzowcdaavrjixhw.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhhcWx3dXpvd2NkYWF2cmppeGh3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg3OTkzMTgsImV4cCI6MjEwNDM3NTMxOH0.nBlXPCOcssR4HqHeFnTXcGc-CwD-_nVRuCRmVMpoHmo';

// window.supabase is provided by the CDN script
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Expose globally so auth.js and db.js can use it
window.supabaseClient = supabaseClient;
