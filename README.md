# Kerya Maize Industry — Management Information System

Inventory, production and sales tracking for maize and other grains across the
Main and Rusizi branches.

Static front end (no build step) on top of Supabase for auth, data and
row-level security.

## Layout

```
index.html                  markup for every view (single page, shown/hidden)
script.js                   view logic, charts, forms
style.css                   all styling
src/supabaseClient.js       project URL + anon key, creates the client
src/auth.js                 login, logout, session restore
src/db.js                   every database call, in one place
supabase/schema.sql         tables, RLS policies, triggers
supabase/seed.sql           the seven initial profiles
supabase/migrations/        incremental changes — run in numeric order
```

## Setup

1. Run `supabase/schema.sql` in **Supabase Dashboard → SQL Editor**
2. Create the seven auth users in **Authentication → Users**
   (emails are `<username>@kerya.com`)
3. Run `supabase/seed.sql`
4. Run `supabase/migrations/001_security_and_integrity.sql`
5. Run `supabase/migrations/002_product_model.sql`
6. Run `supabase/migrations/003_dynamic_branches.sql`
7. Run `supabase/migrations/004_admin_delete_and_logging.sql`
8. Run `supabase/migrations/005_password_management.sql`
9. Deploy the password-reset function (optional but recommended):
   `supabase functions deploy admin-reset-password` — see
   [supabase/functions/admin-reset-password/README.md](supabase/functions/admin-reset-password/README.md)
8. Read **[SECURITY.md](SECURITY.md)** and complete the manual steps —
   rotating the seeded passwords and disabling public signup

Steps 4 to 7 are not optional. 001 adds stock validation, an atomic production
insert and an unforgeable audit trail; 002 builds the product model the plant
actually runs on; 003 turns branches into data so a new one can be opened
without a schema change; 004 makes deletion admin-only, logged and stock-safe.

## How the business model maps to the data

* Maize is **bought in kg** at Main. Quantity minus waste is **cleaned maize**,
  which is either milled or sold as-is.
* Milling produces **either Semoule or Ordinaire**, never both in one run.
  * **Semoule** has a processing rate (68% by default, switchable). The
    remainder comes out as **bran**.
  * **Ordinaire** is a mixture of everything — 100% yield, no bran, no rate.
* Semoule and Ordinaire are stocked and sold **as sacks**: Semoule 25/10/5kg,
  Ordinaire 50/25kg. Bran and Cleaned Maize are sold by weight.
* Prices are entered **per sale**, because they move.
* **A depot sells only what has been transferred to it.** The sending branch
  dispatches, the receiving branch confirms what actually arrived, and any
  shortfall is recorded as a variance.

## Branches

Branches are rows, not code. An admin opens one from the **Branches** screen and
chooses its type:

* **Production site** (like Main) — buys maize, mills it, holds bulk stock,
  packs sacks, dispatches to others, sells everything.
* **Sales depot** (like Rusizi) — receives transfers and sells Semoule and
  Ordinaire only.

Menus, product lists, branch pickers, stock and report filters are all derived
from that list, so a new branch appears everywhere with the right capabilities.
Branches are never deleted — closing one stops new entries while keeping its
history.

## Reports

Type × Branch × Period, combinable. Period covers all time, monthly, quarterly,
yearly or a custom range — so "the quarterly sales of Rusizi in 2025" is a
three-dropdown query. Download as **PDF** or **Excel**; both carry the scope and
period in the filename.

Full detail, and the assumptions still worth confirming, are in
[SECURITY.md](SECURITY.md).

Serve the folder over HTTP rather than opening `index.html` from disk:

```bash
python -m http.server 8000
```

## Roles

| Role | Sees | Can write |
|---|---|---|
| `admin` | everything | everything, plus users, branches and deletion |
| `manager` | all branches | purchases, production, sales, transfers; reads the log |
| `staff` | own branch only | whatever that branch does — a depot sells and receives, a production site also buys and mills |
| `stakeholder` | all branches | nothing — read-only |

Branch scoping is enforced by row-level security in the database, not by the
front end. Hiding a menu item is a convenience, never a control.

**Only an admin can delete a record,** and only through a function that logs the
deletion in the same transaction and refuses anything that would leave stock
negative. See [SECURITY.md](SECURITY.md) §9–10 for the full matrix.

## Known gaps

See the "Known gaps" section of [SECURITY.md](SECURITY.md) before relying on
this for anything financial.
