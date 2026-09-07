# Kerya Maize — Security & Deployment Notes

Read this before putting the system in front of real staff.

---

## 0. Open questions for the owners

Three decisions the system is waiting on — **see section 14** for the detail:

1. **Missing sacks in transit** — what happens when 2 of 20 do not arrive?
2. **Selling currency** — should a border branch sell in USD or Congolese francs?
3. **The processing cap** — should milling be capped at available stock?
   (It currently is. Dropping `trg_check_production_stock` removes the cap.)

---

## 1. Apply the migrations

Run these in order in **Supabase Dashboard → SQL Editor**:

1. `supabase/migrations/001_security_and_integrity.sql`
2. `supabase/migrations/002_product_model.sql`
3. `supabase/migrations/003_dynamic_branches.sql`
4. `supabase/migrations/004_admin_delete_and_logging.sql`
5. `supabase/migrations/005_password_management.sql`
6. `supabase/migrations/006_phone_rules.sql`
7. `supabase/migrations/007_international_phones_and_vehicle.sql`
8. `supabase/migrations/008_optional_sale_phone.sql`
9. `supabase/migrations/009_multi_item_dispatch.sql` — **run once only**

Migration 002 rebuilds the product model around how the plant actually works
(see section 5). Read its **STEP 0** first — it converts existing rows rather
than dropping them, and some of those conversions are inferences you should
check afterwards.

Migration 003 turns branches into rows (section 6). Main and Rusizi keep
behaving exactly as they do now; they simply stop being hardcoded strings.

Run **STEPS 1–4 first**, then this check:

```sql
SELECT 'Main' AS branch, * FROM public.branch_stock('Main')
UNION ALL
SELECT 'Rusizi', * FROM public.branch_stock('Rusizi');
```

Every number must be `>= 0`. Step 4 installs triggers that reject any sale or
production which would drive stock negative — if the existing data is *already*
negative, those triggers will block all further entries for that branch until
the underlying records are corrected. Fix the data first, then run STEP 5.

---

## 2. Manual steps that cannot be done in code

### Rotate every password

The repository previously contained `demo_account_pass.txt` with working
credentials for all seeded accounts (`admin/admin123`, `manager/mgr123`,
`staffmain/staff123`, `staffrusizi/staff123`, `boss1/boss123`, `boss2/boss123`).

That file has been removed from the project, but **assume those passwords are
compromised**. In Supabase Dashboard → Authentication → Users, reset the
password on every account before go-live.

### Disable public signup

**Authentication → Sign In / Providers → disable "Allow new users to sign up."**

The signup trigger no longer trusts client-supplied roles, so a self-registered
account can only ever become an inactive staff member on Main. But unless you
actually want public registration, turn it off.

### Turn on point-in-time recovery

Supabase's free tier keeps daily backups only. For a system of record holding
purchase and sales ledgers, enable PITR on a paid plan, or schedule your own
`pg_dump` off-site.

---

## 3. What the migration changed, and why

| Issue | Before | After |
|---|---|---|
| **Privilege escalation** | `profiles_update_staff_own` had no `WITH CHECK`, so Postgres reused `USING` as the check. Both conditions still passed after the change — a staff user could `PATCH` their own row to `role = 'admin'` and gain both branches plus delete rights. | Policy replaced, plus a `guard_profile_update()` trigger that pins `role`, `branch`, `active` and `username` for non-admins. Managers cannot grant or revoke `admin`. Nobody can deactivate their own account. |
| **Signup trigger** | `handle_new_user()` read `role` and `branch` from `raw_user_meta_data`, which is entirely client-controlled. With signup enabled, anyone could register as an admin. | Role and branch are hardcoded to `staff` / `Main`, and the account is created **inactive**. An admin promotes and activates it from the Users screen. |
| **Forgeable audit trail** | `recorded_by` / `performed_by` were sent by the browser with no constraint. Any user could attribute entries to a colleague. | Columns `DEFAULT auth.uid()`, and every INSERT policy now requires `recorded_by = auth.uid()`. The client no longer sends the field at all. |
| **No stock validation** | Nothing stopped a sale of 10,000 kg of flour that did not exist. `loadInventory()` clamped negatives to zero with `Math.max(0, …)`, hiding the problem. | `check_sale_stock()` and `check_production_stock()` triggers reject overdrawn writes, serialised per branch with `pg_advisory_xact_lock` so concurrent sales cannot both pass. Inventory now displays true values, red when negative. |
| **Non-atomic production** | Production row inserted, then five sack rows, with a hand-rolled JavaScript "rollback". A closed tab in between left an orphan. | Single `create_production()` function, one transaction. `SECURITY INVOKER`, so RLS still applies. |

---

## 4. Known gaps — still outstanding

These are **not** fixed. They were outside the scope of this pass.

1. **User creation is still a two-step manual process.** Creating an auth user
   needs the `service_role` key, which must never reach the browser. The
   "+ Add User" button explains the workflow rather than performing it. The
   proper fix is a Supabase Edge Function holding the service key, invoked via
   `supabaseClient.functions.invoke('create-user', …)`.

2. **Stock triggers cover `INSERT` only, not `UPDATE` or `DELETE`.** An
   admin editing or deleting a historical production row can still push stock
   negative. Only admins and managers have those rights, and `activity_log`
   remains append-only, so it is auditable — but it is not prevented.

3. **No pagination.** Reports, analytics and the record tables still fetch
   entire tables and aggregate in the browser. Fine at a few thousand rows;
   it will degrade after a year or two of daily entries. The inventory screen
   reads a server-side aggregate — the reports screen should follow.

4. **No tests, no staging environment, no error monitoring.** Every change is
   currently verified by hand against production data.

5. **Transfers cannot be corrected once confirmed.** Only an admin can touch a
   confirmed transfer, and even then there is no UI for it — it has to be done
   in the SQL editor. A "reverse transfer" flow would be better than editing
   settled records.

---

## 5. The product model (migration 002)

Rebuilt to match how the plant actually works, from the branch users' feedback.

| Rule | How it works |
|---|---|
| **Purchases are in kg** | The ton option is gone from the form *and* the schema. Quantity is the gross delivery, waste is deducted, and the remainder — the cleaned maize — is what enters stock. |
| **One product per run** | Milling produces Semoule **or** Ordinaire, never both. The form asks which before showing anything else. |
| **Semoule has a processing rate** | Default 68%, switchable per run. Output and bran are derived from it: 1000kg at 68% gives 680kg semoule and 320kg bran. The split is computed in `create_production()`, not the browser. |
| **Ordinaire has no rate and no bran** | A mixture of everything: 100% yield. The rate control and bran figure are hidden, and a database CHECK rejects any ordinaire row carrying bran. |
| **Semoule and Ordinaire are stocked as sacks** | Not loose kg. Semoule 25/10/5kg, Ordinaire 50/25kg. Selling 30 × 25kg sacks requires 30 real 25kg sacks to exist. |
| **Prices are entered per sale** | Per sack for Semoule/Ordinaire, per kg for Bran and Cleaned Maize. Nothing is stored as a "standard price" because prices move. |
| **Cleaned Maize replaces Maize Grains** | Same product, renamed everywhere. It is purchased maize with the waste taken out, and is either milled or sold as-is. |
| **Production is Main only** | Enforced by a CHECK constraint, not just the UI. Rusizi staff do not see the screen. |
| **Rusizi sells only what Main sent** | Its stock is confirmed transfers minus sales. A CHECK constraint stops any other product being sold there. |

### How transfers work

A dispatch is a **delivery note** (migration 009): one trip carrying many lines.

```
TRF-0001   Main → Rusizi   RAD 123 A   Driver Eric
  Ordinaire  50 kg   20 sacks
  Semoule    25 kg   30 sacks
  Semoule     5 kg   40 sacks
```

Two steps, deliberately:

1. **The sender dispatches.** The sacks leave its stock immediately.
2. **The receiver confirms**, line by line, how many actually arrived — which
   may be fewer. Only then do they enter the receiving branch's stock.

Sacks in flight belong to neither branch, and the inventory screen says so.
A shortfall is recorded as a **variance on the line it happened on**, so you
know which product went missing rather than just that the note was short. The
receiver cannot confirm more sacks than were sent, and cannot edit what the
sender recorded as dispatched.

Stock is checked on the **total per sack size across the whole note**, not per
line: two lines of 40 against 70 in stock is 80 requested, and is refused.

**No conflict-resolution flow exists yet.** A variance is detected, recorded and
visible — but the missing sacks then leave the books entirely: nobody accepts
the loss, the sender cannot contest the receiver's count, and there is no route
to correct it if the sacks turn up the next day. See "Open questions".

### Assumptions to confirm

Made while building this. All are cheap to change if wrong:

1. **Purchases are booked to Main only.** The branch picker is gone from the
   purchase form. Rusizi receives finished sacks and never buys raw maize, so a
   Rusizi purchase would create cleaned maize stock that nothing at that branch
   could ever draw down. Say the word if Rusizi does buy maize directly.

2. **Bran comes only from Semoule runs**, and is stocked and sold at Main in kg.

3. **Sacks may total less than the milled output** — the difference is treated
   as loose product and the form warns rather than blocks. Packing *more* than
   was milled is rejected, since that would create stock from nothing.

4. **Historical `Flour` sales are preserved read-only.** The value stays valid
   in the database so old rows remain truthful, but it is not offered in the UI
   and `check_sale_stock()` rejects any new sale using it.

5. **The old `grains_kg` production column is dropped.** Cleaned Maize is now
   derived from purchases, so recording it as a production output as well would
   double-count it.

---

## 6. Opening a new branch (migration 003)

Branches used to be baked into CHECK constraints on six tables, into the stock
function, and into the direction of a transfer. Opening a third branch meant a
schema change. They are now rows, and opening one is a data change made from
the **Branches** screen by an admin.

### The one decision that matters

Each branch carries a **can produce** flag, which is what actually
distinguishes the two kinds of site:

| Type | Behaves like | Can | Cannot |
|---|---|---|---|
| **Production site** | Main | Buy maize, mill it, hold bulk stock, pack sacks, dispatch, sell everything | — |
| **Sales depot** | Rusizi | Receive transfers, sell Semoule and Ordinaire | Buy maize, mill, sell Bran or Cleaned Maize |

Nothing in the code names a branch any more. Menus, product lists, branch
pickers, stock figures and the report filter are all derived from the list, so
a new branch appears everywhere at once with the right capabilities.

The rules are enforced in the database, not just hidden in the UI: triggers
reject a purchase or production run at a depot, and reject a bulk sale there.

### Transfers now run between any two branches

Migration 002 fixed the direction as Main → Rusizi. Any branch can now send to
any other. The stock check on the sending side is what keeps it honest, and the
two-step confirm works the same way: stock leaves on dispatch, arrives on
confirmation, and any shortfall is recorded as a variance.

### Safeguards

* A branch is **never deleted** — there is no DELETE policy. Closing one stops
  new entries but keeps its history, so past records stay meaningful.
* **`All` is reserved.** It is the sentinel for "every branch" on a user
  profile; a CHECK constraint stops it being used as a real branch name.
* Turning off production for a branch still holding cleaned maize is
  **blocked**, since that stock would otherwise be stranded with no mill to
  consume it and no way to sell it.
* Renaming a branch cascades to its history rather than orphaning it.

### Assumption to confirm

**Only sacks are transferable.** Bulk product (cleaned maize, bran) cannot be
moved between branches, matching how Rusizi works today. If a depot should be
able to receive bran to sell, `transfers` needs a bulk variant and the depot's
sale rule needs relaxing.

---

## 7. Interface changes from branch-user feedback

**Mobile navigation was broken.** The sidebar goes off-canvas below 768px and
`.sidebar.open` existed in the stylesheet, but nothing could ever set it —
there was no control. Phone users were stranded on whichever view loaded first.
Added a topbar toggle, a tap-to-dismiss backdrop, and auto-close on navigation.

**Stat cards clipped their values.** `.stat-card` has `overflow: hidden` and
the value was a fixed `1.8rem`, so anything past about seven digits was simply
cut off — `15,705,000` rendered as `15,705,0`. Values now scale with the
viewport and wrap instead of being clipped, cards sit two-per-row on a phone
rather than one giant column, and tables scroll inside their own box rather
than pushing the page sideways.

**Two analytics charts removed** as having nothing to say yet:

* *Production Efficiency* — repeated the dashboard's Production Summary
  doughnut exactly.
* *Weekly Trend* — needs months of history before its line means anything, and
  the dashboard's 7-day sales chart already covers recent activity.

*Revenue by Branch* was kept and generalised to any number of branches, and a
**Branch Summary** table was added showing sales count, quantity and revenue
per branch. Both removed charts are easy to restore — say the word.

---

## 8. Reports

Reports combine three independent filters, so a request like *"the quarterly
sales of Rusizi in 2025"* is Type = Sales, Branch = Rusizi, Period = Quarterly,
Year = 2025, Quarter = Q1.

| Filter | Options |
|---|---|
| **Type** | Full Summary, Purchase, Production, Sales |
| **Branch** | All Branches, or any single branch |
| **Period** | All time, Monthly, Quarterly, Yearly, Custom range |

Periods are resolved in local time, so "Q1 2025" means Q1 as experienced in
Rwanda, not in UTC. Filtering happens in the database, so a one-quarter report
fetches one quarter rather than the whole table.

Both **PDF** and **Excel** downloads carry the scope and period in the
filename — `Kerya_sales_Rusizi_Q1-2025.xlsx` — and the Excel workbook opens
with a *Report Info* sheet stating the type, branch, period, generation date
and row counts, so a downloaded file is still meaningful months later.

---

## 9. Who can do what

Menus, on-screen controls and database policy are all aligned. The database is
the real guard — the UI only removes clutter, so hiding a button is never the
thing keeping anyone out.

| | Admin | Manager | Staff (production site) | Staff (depot) | Stakeholder |
|---|:---:|:---:|:---:|:---:|:---:|
| Dashboard | ✓ | ✓ | ✓ | ✓ | ✓ |
| Record purchases | ✓ | ✓ | ✓ own branch | — | — |
| Record production | ✓ | ✓ | ✓ own branch | — | — |
| Record sales | ✓ | ✓ | ✓ own branch | ✓ own branch | — |
| Dispatch transfers | ✓ | ✓ | ✓ from own branch | ✓ from own branch | — |
| Confirm arrivals | ✓ | ✓ | ✓ to own branch | ✓ to own branch | — |
| Inventory | ✓ all | ✓ all | ✓ own branch | ✓ own branch | ✓ all |
| Reports & analytics | ✓ | ✓ | — | — | ✓ |
| Activity log | ✓ | ✓ | — | — | — |
| **Delete records** | ✓ | — | — | — | — |
| Manage users | ✓ | — | — | — | — |
| Manage branches | ✓ | — | — | — | — |

Staff see only their own branch's data — enforced by row-level security, and by
`branch_stock()` refusing to report another branch's position. Stakeholders have
read policies only; they have no INSERT policy anywhere, so the role is
structurally read-only rather than read-only by convention.

Navigating to a screen outside your own menu is refused rather than rendered,
so a view cannot be reached from the browser console either.

---

## 10. Deletion and the audit trail (migration 004)

### Deletion

Managers previously had raw `DELETE` rights on purchases, productions and sales
— unlogged, with nothing stopping a delete that broke the stock arithmetic.
**That is withdrawn.** No role has a `DELETE` policy any more.

Deletion happens only through `admin_delete_record(entity, id, reason)`, which:

* is **admin only**;
* **requires a reason** of at least 3 characters;
* captures a **full JSON snapshot** of the row *before* deleting it;
* writes the audit entry **in the same transaction** as the delete, so an
  unlogged deletion is not possible — if the log write fails, the delete
  rolls back;
* **refuses anything that would leave stock negative.** Deleting a purchase
  whose maize has already been milled is rejected, naming the branch and the
  shortfall, and the delete is rolled back.

Deletions are recorded at `critical` severity with the snapshot attached, so a
mistaken delete can be reconstructed from the log.

`activity_log` itself still has no UPDATE or DELETE policy, for anyone. That is
what makes it an audit trail rather than a table.

### The Activity Log screen

Admins and managers get a **Activity Log** screen: filter by period, severity,
branch, user and free text, with counts by severity and CSV export. Filtering
runs in the database, so searching does not pull the whole table into the
browser.

Three severities: **routine** (day-to-day entries), **notable** (role changes,
branch changes), **critical** (deletions).

Database triggers log the structural changes the app cannot see for itself —
role changes, activations, branch openings and closures — so those cannot be
made silently even by someone working directly against the database.

**Gap worth knowing:** sign-ins and sign-outs happen inside Supabase Auth,
outside this schema, so they are not in this log. Supabase keeps its own auth
logs in the dashboard. Wiring them together would need an Edge Function.


---

## 11. Passwords (migration 005)

Passwords live in Supabase Auth, not in this schema, so there are two separate
paths.

### Anyone changes their own

**Change my password** in the sidebar. Goes straight through Supabase Auth with
the user's own session — no privileged key, nothing to deploy, works as soon as
migration 005 is applied. The change is recorded in the activity log.

### An admin resets someone else's

**Users → Reset.** The admin types or generates a temporary password, reads it
out to the person, and:

* the target is flagged `must_change_password`;
* at their next sign-in they are held on a **Choose a new password** screen and
  cannot reach the system until they set their own;
* the reset is logged at `critical` severity naming the admin who did it.

So an admin can restore access to a locked-out user **without ever holding a
working password for that account** beyond the handover.

Generated suggestions avoid look-alike characters (`O/0`, `I/l/1`) and come in
`XXXX-XXXX-XXXX` groups, because they get read out over the phone.

### Why this needs an Edge Function

Changing *another* user's password requires the `service_role` key, which can
do anything to the database and must never reach a browser. The reset therefore
runs in `supabase/functions/admin-reset-password`, on Supabase's servers, where
that key is injected as an environment variable.

The function re-checks that the caller is an active admin **against the
database** — the request body has no say in it — and refuses passwords under 8
characters or on a short obvious-guess list.

**Until it is deployed**, the Reset button says so plainly and points the admin
at Supabase Dashboard → Authentication → Users. Nothing else is affected;
self-service password changes work regardless.

### Residual gap

A determined user could clear their own `must_change_password` flag through the
API without actually changing their password, since the database cannot verify
that an Auth password change happened. The consequence is only that they skip a
prompt on an account they are already signed into, so it is not worth the
complexity of closing — but it is not airtight, and is recorded here as such.

---

## 12. Phone numbers (migrations 006–008)

**Optional on both sides.** A farmer may arrive with maize and no phone; a
walk-in customer may pay cash and leave no number. A mandatory field would only
push staff into typing a placeholder, which is worse than an honest blank. NULL
means none given — never an empty string, so "no phone" has one representation.

Where a number IS given, the rule turns on whether it starts with `+`:

| Written | Treated as | Checked for |
|---|---|---|
| `+243 991 234 567` | International | Plausible length (E.164, 8–15 digits) |
| `0788 123 456` | Local shorthand | Must be a Rwandan mobile |

Rusizi sits on the DRC border, so Congolese and Burundian customers are ordinary
business, not errors. Only Rwanda's shorthand can be interpreted, so a foreign
number typed **without** its `+` is refused rather than guessed at.

Rwandan numbers are stored as `+250 788 123 456`; foreign ones keep their own
digits (`+243991234567`), since grouping conventions differ by country and
guessing would mangle them.

Enforced by CHECK constraints on both tables, so a tampered client cannot
bypass it. Landlines (`025…`) are deliberately refused — widen the pattern in
006 if a supplier ever gives one.

---

## 13. Multi-item dispatches (migration 009)

Until 009 a transfer was one product, one sack size, one count. A lorry with
three different loads had to be entered as three transfers, each confirmed
separately, with the plate retyped each time. The arithmetic was right, but the
record did not say that one truck made one trip.

| Table | Holds |
|---|---|
| `transfers` | the trip — reference, from, to, plate, note, date, status |
| `transfer_items` | the load — one line per product and sack size |

Each dispatch carries a reference (`TRF-0001`) so staff can name it on the phone
rather than describe it. The truck plate is optional and carries **no
country-specific pattern** — lorries cross from the DRC on Congolese plates, and
refusing those would be the same mistake as refusing foreign phone numbers.

Two bugs were found and fixed while testing this against a real database, both
of which only appear on execution:

* **Duplicate lines lost stock.** Entering 40 then another 40 of the same sack
  passed a check for 80 but stored only 40 — so 40 sacks would have left the
  sending branch unrecorded. One aggregate now drives both the check and the
  insert, so what is validated is exactly what is written.
* **The refusal message lied.** It reported stock *after* the pending rows were
  inserted, producing "−929 in stock". Stock is now checked before anything is
  written.

---

## 14. Open questions for the owners

Three decisions the system is waiting on. Each is written to be easy to change
once answered.

1. **Missing sacks in transit.** When 2 of 20 do not arrive, what happens? The
   variance is recorded, but the sacks then leave the books — nobody accepts the
   loss, the sender cannot contest the count, and there is no route to correct it
   if they turn up later. The right design depends on what the branches already
   do in practice.

2. **Selling currency.** Should a border branch sell in USD or Congolese francs?
   If so, the thing to settle is whether each sale also records its RWF value —
   without that, revenue cannot be totalled across currencies.

3. **The processing cap.** Should milling be capped at available stock? It
   currently is. Uncapping is one line, but cleaned maize can then go negative
   and inventory becomes advisory rather than a record.
