# Edge Function — admin-reset-password

Changing another user's password needs the `service_role` key. That key can do
anything to your database and **must never be in the browser**, so the reset
runs here, on Supabase's servers, instead.

Users changing their *own* password do not need this function at all — that
goes straight through Supabase Auth from the app.

## Deploying it

You only do this once. It needs the Supabase CLI.

**1. Install the CLI**

```bash
npm install -g supabase
```

**2. Sign in**

```bash
supabase login
```

A browser window opens; approve it.

**3. Link this project**

Your project ref is the part of your project URL before `.supabase.co` —
for `https://abcdefghijk.supabase.co` the ref is `abcdefghijk`. Find it under
Project Settings → General.

```bash
supabase link --project-ref YOUR_PROJECT_REF
```

**4. Deploy, from the repository root**

```bash
supabase functions deploy admin-reset-password
```

That is it. `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`
are injected by Supabase automatically — do not set them yourself, and do not
put them in any file.

**5. Check it**

Sign into the app as an admin, open **Users**, and use **Reset password** on a
test account. Then sign in as that account: it should force you to choose a new
password before letting you in.

## If it will not deploy

The app degrades honestly: the Reset password button reports that the function
is not deployed and points the admin at the dashboard instead
(Authentication → Users → the user → Reset password). Nothing else breaks.

## What it refuses

* Anyone who is not a signed-in, **active admin** — checked against the
  database, not against anything the request claims.
* Passwords under 8 characters.
* A short list of obvious ones (`password`, `admin123`, `kerya123`, …).

## What it records

Every reset writes a `critical` entry to the activity log naming the admin who
did it and the account affected, and sets `must_change_password` on the target.
The user must choose their own password at next sign-in, so an admin never
keeps working knowledge of a live password.
