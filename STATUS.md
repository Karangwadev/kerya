# Kerya Maize MIS — System Flow & Readiness Report

*Revised 8 September 2026. Covers phone rules, multi-line dispatches, and the
full run against a real PostgreSQL instance.*

---

## Part 1 — How the system works, in plain words

### The one-line version

Maize is bought at a production site, cleaned, milled into Semoule or
Ordinaire, packed into sacks, either sold there or sent to a depot, and sold.
Every step moves stock, and the system will not let you move stock you do not
have.

### Step by step

**1. Buying**
Someone at a production site records a delivery: supplier, gross weight in
kilos, price per kilo, and how much waste was taken out. A phone number is
optional — a farmer may not have one. Gross weight minus
waste is the **cleaned maize**, and that is what enters stock. Everything is in
kilos; there is no ton option.

**2. Milling**
The operator picks what they are making — this is the first thing the form
asks, because the two products behave differently:

* **Semoule** — refined. A processing rate (68% by default, changeable per run)
  splits the maize: 1,000kg at 68% gives 680kg of semoule and 320kg of bran.
* **Ordinaire** — a mixture of everything. All 1,000kg comes out as ordinaire,
  and there is no bran and no rate to set.

The output is then packed into sacks — Semoule in 25/10/5kg, Ordinaire in
50/25kg. The screen reconciles as you type: pack more than you milled and it
refuses; pack less and it tells you how much is left loose.

**3. Moving stock to another branch**
A depot has no mill, so it only ever sells what has been sent to it.

A dispatch is a **delivery note**: one trip, carrying many lines. A line is one
type of sack. So a lorry with three different loads is one entry:

```
TRF-0001   Main → Rusizi   RAD 123 A   Driver Eric
  Semoule    25 kg  ×  30 sacks
  Ordinaire  50 kg  ×  20 sacks
  Semoule     5 kg  ×  40 sacks
```

Two steps on purpose:

* The sending branch records the dispatch — the sacks leave its stock straight
  away.
* The receiving branch confirms **what actually arrived**, line by line, which
  may be fewer. Only then do the sacks enter its stock.

Anything sent but not yet confirmed is "in transit" and belongs to neither
branch — the inventory screen says so explicitly. If 20 ordinaire were sent and
18 arrived, the 2 are recorded as a **variance against that line**, so you know
which product went missing. Each note has a reference so it can be named on the
phone rather than described.

**Not yet settled:** a variance is recorded, but the missing sacks then leave
the books. Nobody accepts the loss, and the sender cannot contest the count.
That is a question for the owners.

**4. Selling**
Semoule and Ordinaire are sold **by the sack**: pick the size, the number of
sacks, and the price for a sack today. Bran and Cleaned Maize are sold by
weight. Prices are typed in every time, because they move.

A depot can only sell Semoule and Ordinaire. A production site can also sell
bran and cleaned maize, because it is the only place those exist.

The customer's phone is optional too — a walk-in may pay cash and leave no
number. Where one is given it is checked, and foreign numbers are accepted with
their country code, since Rusizi is on the DRC border.

**5. Stock, always**
Stock is calculated in the database, in one place, and the sales screen, the
inventory screen and the rules that block bad entries all read from it. They
cannot disagree. You cannot sell 30 sacks if 18 are in the store; you cannot
mill 5 tonnes if 2 are in the yard.

**6. Reports**
Pick a type (purchases, production, sales, or everything), a branch, and a
period — a month, a quarter, a year, or your own dates. Download as PDF or
Excel. "The quarterly sales of Rusizi in 2025" is three dropdowns.

**7. Opening a branch**
An admin adds it from the Branches screen and picks its type: a **production
site** behaves like Main (buys, mills, dispatches, sells everything), a **sales
depot** behaves like Rusizi (receives transfers, sells sacks only). Every menu,
product list and stock figure follows automatically. Branches are never
deleted — closing one keeps its history.

**8. Getting people in and out**
An admin creates the account in Supabase, then sets the person's role and
branch in the app and activates them. Anyone can change their own password from
the sidebar. If someone is locked out, an admin resets it to a temporary
password and reads it out — the person is then **made to choose their own** at
next sign-in, so the admin never holds a working password.

**9. Watching it**
Every action is logged: who, what, when, which branch. Admins and managers can
search that log. Deleting a record is admin-only, needs a written reason, keeps
a full copy of what was deleted, and is refused outright if it would make the
stock figures impossible.

### Who does what

| Role | What they do |
|---|---|
| **Staff at a production site** | Buy maize, mill it, sell, dispatch to depots |
| **Staff at a depot** | Confirm arrivals, sell sacks |
| **Manager** | All of the above at every branch, plus reports and the log |
| **Stakeholder** | Looks only — dashboards, reports, inventory. Cannot enter anything |
| **Admin** | Everything, plus users, branches, passwords and deletion |

Staff only ever see their own branch. That is enforced in the database, not by
hiding buttons.

---

## Part 2 — How far along is it?

### The honest answer: **deployment has started; nothing is proven yet.**

```
  1. Prototype ──▶ 2. Feature-complete ──▶ 3. Staging ──▶ 4. Pilot ──▶ 5. Production
                        ▲ HERE, moving into 3
```

Three different things sit at three different levels:

| | Where it is |
|---|---|
| **Code written** | Complete for everything asked for |
| **Deployed** | Just begun — a new Supabase project exists, `schema.sql` has run |
| **Proven** | Nothing. Nobody has signed in and used it |

### What is genuinely done

* All requested features are built and consistent end to end.
* Security holes from the first review are fixed: the privilege-escalation
  path, the signup trigger that trusted the browser, the forgeable audit trail.
* The stock model is enforced in the database, so a tampered client cannot
  write impossible figures.
* Roles are aligned across menus, screens and database policy, and verified.
* Deletion is admin-only, always logged, and refused if it would break stock.
* Works on a phone.
* ~130 behavioural checks run in a browser against the real page.

### The one thing most likely to waste your afternoon

**`src/supabaseClient.js` still points at the OLD Supabase project.**

```js
const SUPABASE_URL = 'https://tcdkgnfuxssxevcpttum.supabase.co';
```

Swap the URL and anon key for the new project's (Project Settings → API). Until
then the app will run, look completely normal, and talk to the wrong database.

### What stands between here and real use

**Immediate — you are in this stretch now:**

1. **Repoint `src/supabaseClient.js`** at the new project. Two minutes.
2. **Run migrations 006 → 009 in order.** 001–005 are already applied to your
   project. 009 must be run **once only** — it drops columns it also reads.
3. **Create the auth users** in the dashboard, then run `seed.sql`.
4. **Rotate every password** and **disable public signup**.
5. **Deploy the Edge Function** for in-app password resets — optional; the
   Supabase dashboard covers it meanwhile.

**Then, the real threshold:**

6. **Sign in and do one full cycle**: buy → mill → transfer → confirm → sell →
   report. This has never been done once. Every check so far used a stubbed
   database. This is where the remaining bugs surface.
7. **Host it** — Netlify, Vercel or Cloudflare Pages, free for a static site.
8. **Turn on backups.** The free tier keeps daily snapshots only, which is thin
   for a sales ledger. Point-in-time recovery needs a paid plan.

**Then the part that cannot be rushed:**

9. **Two weeks at Main: real entries, on paper as well, comparing the two.**

### About the SQL

All nine migrations have now been **executed against a real PostgreSQL 18
instance** with a stand-in for Supabase's auth, and the whole business cycle run
through them: buy, mill, dispatch a three-line truck, confirm short, sell,
delete. Every closing figure was reconciled by hand, and every guard was tested
by trying to break it.

That testing found and fixed five bugs that only appear on execution — a
`min(uuid)` call that does not exist, two ambiguous column references, a
password flag silently reverted by its own guard trigger, and duplicate dispatch
lines that passed a check for 80 sacks but stored 40.

What it does **not** prove: that RLS behaves identically under Supabase's real
JWT handling, since the harness stubs `auth.uid()`. Send any error text and it
can be corrected.

### Known gaps, liveable for now

* Adding a user is half-manual: create in Supabase, then set role and branch in
  the app.
* Reports and record tables load everything and page in the browser. Fine for a
  year or two.
* Sign-ins are not in the activity log — they happen inside Supabase Auth.
* Stock rules cover new entries and deletions, but **not edits to old records**.
* A user could clear their own forced-password-change flag via the API without
  changing their password. Low consequence; documented in SECURITY.md §11.
* No automated test suite in the repository — the checks were run by hand.

### Suggested route

| Stage | What happens | Roughly |
|---|---|---|
| **1. Point & migrate** | Repoint the client, run 001–005, fix errors as they come | An afternoon |
| **2. Secure** | Rotate passwords, disable signup, turn on backups | An hour |
| **3. Walk through** | One person does a full day's cycle end to end. Fix what surfaces | A day or two |
| **4. Host** | Deploy to a static host, hand out the URL | An hour |
| **5. Pilot** | Main only, real entries, paper in parallel, compare | 2 weeks |
| **6. Live** | Add the other branches, drop the paper | — |

Do not skip stage 5. The stock arithmetic is the whole value of the system, and
the only way to know it matches the store is to count the store.

### Assumptions that would make the numbers wrong if they are wrong

These will not throw errors. They will quietly produce confident, incorrect
figures — which is what stage 5 exists to catch. Worth putting to whoever runs
the mill:

1. **Cleaned Maize comes from purchases** (quantity minus waste), not from
   milling.
2. **Ordinaire yields 100%** of the maize put in, with no bran.
3. **Semoule defaults to 68%**, changeable per run.
4. **Only sacks move between branches** — not bulk bran or cleaned maize.

### Three decisions still waiting on the owners

1. **Should milling be capped at available stock?** It currently is. Uncapping
   is one line, but then cleaned maize can go negative and inventory becomes
   advisory rather than a record.
2. **Should a depot be able to receive bran or cleaned maize?** Today only
   sacks can be transferred.

3. **What happens when sacks go missing in transit?** The variance is recorded,
   but the missing sacks then leave the books — nobody accepts the loss, the
   sender cannot contest the receiving branch's count, and there is no route to
   correct it if they turn up the next day. The right design depends on what the
   branches already do in practice.

---

## In one paragraph

The system is a complete, coherent build of what was asked for, with the data
integrity rules where they belong — in the database — rather than in the browser
where they could be bypassed. Deployment has begun: a Supabase project exists
and the base schema is in. But the app still points at the old project, none of
the five migrations has finished running, and nobody has signed in and used it.
The distance to a working pilot is small and mostly mechanical — repoint the
client, get the migrations through, walk one full day of operations, put it on a
host. The distance to *trusting it with the books* is longer, and runs through a
fortnight of parallel running against the paper records.