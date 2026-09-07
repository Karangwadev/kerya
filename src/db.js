// ============================================================
// KERYA MAIZE — Database Layer
// Loaded as a regular <script> (no type="module").
// Requires supabaseClient.js and auth.js to be loaded first.
//
// Every database call in the app lives here. script.js never
// touches window.supabaseClient directly.
//
// The product model this layer speaks (see migrations/002):
//   * Purchases are in kg. Quantity minus waste = cleaned maize.
//   * Milling produces EITHER Semoule OR Ordinaire, never both.
//       Semoule   — has a processing rate; the remainder is bran.
//       Ordinaire — a mixture of everything; 100% yield, no bran.
//   * Semoule and Ordinaire are stocked and sold AS SACKS.
//       Semoule 25/10/5 kg, Ordinaire 50/25 kg.
//   * Bran and Cleaned Maize are stocked and sold in kg.
//   * Production is Main only. Rusizi sells what Main transfers.
// ============================================================

// NOTE: recorded_by / performed_by / dispatched_by are deliberately
// NOT sent from here. The columns DEFAULT to auth.uid() and RLS
// rejects any other value, so the audit trail cannot be forged by a
// tampered client. Sending an explicit value — even the correct one —
// would suppress the default.

// ── Product constants ─────────────────────────────────────────
// Sack sizes are also a database table (sack_sizes) which is the
// authority; this mirror exists so the UI can render before the
// first round-trip. loadSackSizes() reconciles them at startup.
const SACKED_PRODUCTS = ['Semoule', 'Ordinaire'];
const BULK_PRODUCTS   = ['Bran', 'Cleaned Maize'];

let SACK_SIZES = {
  Semoule:   [25, 10, 5],
  Ordinaire: [50, 25],
};

const DEFAULT_PROCESSING_RATE = 68;   // percent — semoule only

// ── Branch cache ──────────────────────────────────────────────
// Branches are rows, not hardcoded strings (see migrations/003), so
// opening a new one is a data change. This mirror is refreshed at
// launch and after any edit on the Branches screen, so the UI can
// render selectors without a round-trip each time.
//
// A branch's `can_produce` flag is what distinguishes the two kinds
// of site: a producing branch buys maize, mills it and holds bulk
// stock; a non-producing one receives transfers and sells sacks.
let BRANCHES = [];

function branchByName(name) {
  return BRANCHES.find(b => b.name === name) || null;
}

function branchCanProduce(name) {
  return branchByName(name)?.canProduce === true;
}

/** Active branch names, optionally only those that can produce. */
function branchNames({ producingOnly = false, includeInactive = false } = {}) {
  return BRANCHES
    .filter(b => (includeInactive || b.active) && (!producingOnly || b.canProduce))
    .map(b => b.name);
}

/**
 * Products sellable at a given branch. A branch that cannot produce
 * has no way to obtain bulk product, so it sells sacks only.
 */
function productsForBranch(branch) {
  return branchCanProduce(branch)
    ? [...SACKED_PRODUCTS, ...BULK_PRODUCTS]
    : [...SACKED_PRODUCTS];
}

function isSacked(product) { return SACKED_PRODUCTS.includes(product); }

// ── Internal helpers ─────────────────────────────────────────

function applyBranchFilter(query, branchFilter, column = 'branch') {
  if (branchFilter && branchFilter !== 'All') {
    return query.eq(column, branchFilter);
  }
  return query;
}

/**
 * Restrict a query to a date range. `range` is { from, to } as ISO
 * strings, either may be omitted. `to` is EXCLUSIVE — callers pass the
 * instant after the last moment they want, so a period boundary can be
 * expressed without worrying about the last second of the day.
 *
 * Filtering here rather than in the browser means a report for one
 * quarter fetches one quarter, not the entire table.
 */
function applyDateRange(query, range, column) {
  if (!range) return query;
  if (range.from) query = query.gte(column, range.from);
  if (range.to)   query = query.lt(column, range.to);
  return query;
}

/**
 * The database raises human-readable exceptions for stock shortfalls and
 * permission violations (see migrations 001 and 002). Those should reach
 * the user verbatim rather than buried under a generic prefix.
 */
function friendlyError(err, fallbackPrefix) {
  const msg = err?.message || String(err);
  if (/^(Not enough|Not authorised|Only an admin|You cannot|This transfer|Flour is|Sacks add|Semoule needs|Maize processed|Unknown product|Unknown branch|A reason is required|That would leave|Cannot delete)/.test(msg)
      || / (is not an active branch|is not a production branch|cannot buy maize|only sells Semoule|still holds|does not come in|not found)/.test(msg)) {
    return '⚠ ' + msg;
  }
  return fallbackPrefix + ': ' + msg;
}

// ── Field mappers (DB columns → script.js shape) ─────────────

function mapPurchaseRow(row) {
  return {
    id:        row.id,
    supplier:  row.supplier,
    phone:     row.phone,
    tin:       row.tin,
    qty:       row.qty_kg,        // gross, as delivered
    dirt:      row.dirt_kg,       // waste removed
    finalQty:  row.final_qty_kg,  // cleaned maize into stock
    price:     row.price_per_unit,
    total:     row.total_rwf,
    branch:    row.branch,
    entryTime: row.entry_time,
    by:        row.recorded_by,
    createdAt: row.created_at,
  };
}

function mapSaleRow(row) {
  return {
    id:         row.id,
    customer:   row.customer,
    phone:      row.phone,
    product:    row.product,
    sizeKg:     row.size_kg,
    sackCount:  row.sack_count,
    qty:        row.qty_kg,
    unitPrice:  row.unit_price,
    priceBasis: row.price_basis,   // 'sack' | 'kg'
    total:      row.total_rwf,
    branch:     row.branch,
    time:       row.sale_time,
    by:         row.recorded_by,
    createdAt:  row.created_at,
  };
}

function sacksArrayToObject(sackRows) {
  const obj = {};
  (sackRows || []).forEach(r => { obj[r.size_kg] = r.sack_count; });
  return obj;
}

function mapProductionRow(row) {
  return {
    id:      row.id,
    product: row.product_type,                  // 'Semoule' | 'Ordinaire'
    maize:   row.maize_kg,
    rate:    row.processing_rate,               // 0–1, null for Ordinaire
    output:  row.output_kg,
    bran:    row.bran_kg,
    sacks:   sacksArrayToObject(row.production_sacks),  // { 25: 30, 10: 4 }
    time:    row.production_time,
    branch:  row.branch,
    by:      row.recorded_by,
    createdAt: row.created_at,
  };
}

function mapTransferRow(row) {
  // A dispatch is a delivery note: the trip, plus one line per product
  // and sack size. Variance is per line, so a shortfall is recorded
  // against the thing that was actually short.
  const items = (row.transfer_items || []).map(i => ({
    id:       i.id,
    product:  i.product,
    sizeKg:   i.size_kg,
    sent:     i.sacks_sent,
    received: i.sacks_received,
    variance: i.sacks_received === null ? null : i.sacks_sent - i.sacks_received,
    kg:       i.sacks_sent * i.size_kg,
  })).sort((a, b) => a.product.localeCompare(b.product) || b.sizeKg - a.sizeKg);

  return {
    id:           row.id,
    reference:    row.reference,
    fromBranch:   row.from_branch,
    toBranch:     row.to_branch,
    plate:        row.vehicle_plate,
    note:         row.note,
    status:       row.status,
    dispatchedAt: row.dispatched_at,
    dispatchedBy: row.dispatched_by,
    confirmedAt:  row.confirmed_at,
    confirmedBy:  row.confirmed_by,
    items,
    totalSent:     items.reduce((n, i) => n + i.sent, 0),
    totalReceived: items.some(i => i.received === null)
                     ? null
                     : items.reduce((n, i) => n + i.received, 0),
    variance:      items.some(i => i.received === null)
                     ? null
                     : items.reduce((n, i) => n + (i.sent - i.received), 0),
    summary: items.map(i => `${i.sent} × ${i.sizeKg}kg ${i.product}`).join(', '),
  };
}

function mapActivityRow(row) {
  return {
    id:      row.id,
    action:  row.action,
    details: row.details,
    branch:  row.branch,
    by:      row.performed_by,
    byName:  row.profiles?.name ?? null,
    time:    row.created_at,
  };
}

// ── DB Object ─────────────────────────────────────────────────

function mapBranchRow(row) {
  return {
    name:       row.name,
    canProduce: row.can_produce,
    active:     row.active,
    sort:       row.sort,
    createdAt:  row.created_at,
  };
}

const DB = {

  // ─── branches ──────────────────────────────────────────────
  // Adding a branch is a data change. Nothing in the code names a
  // branch; everything reads this list.

  branches: {

    /** Refresh the cache. Returns the full list, inactive included. */
    async load() {
      try {
        const { data, error } = await window.supabaseClient
          .from('branches')
          .select('*')
          .order('sort')
          .order('name');
        if (error) throw error;
        BRANCHES = (data || []).map(mapBranchRow);
        window.BRANCHES = BRANCHES;
        return BRANCHES;
      } catch (err) {
        showToast(friendlyError(err, 'Error loading branches'), 'error');
        return BRANCHES;
      }
    },

    getAll() { return BRANCHES; },

    /**
     * create({ name, canProduce })
     *
     * Admin only, enforced by RLS. 'All' is rejected by a CHECK
     * constraint because it is the sentinel for "every branch" on a
     * user profile and must not collide with a real one.
     */
    async create({ name, canProduce = false }) {
      try {
        const sort = Math.max(0, ...BRANCHES.map(b => b.sort)) + 1;
        const { data, error } = await window.supabaseClient
          .from('branches')
          .insert({ name: name.trim(), can_produce: canProduce, sort })
          .select()
          .single();
        if (error) throw error;
        await DB.branches.load();
        return mapBranchRow(data);
      } catch (err) {
        showToast(friendlyError(err, 'Error creating branch'), 'error');
        return null;
      }
    },

    /** patch may contain { name, canProduce, active }. */
    async update(name, patch) {
      try {
        const payload = {};
        if (patch.name !== undefined)       payload.name        = patch.name.trim();
        if (patch.canProduce !== undefined) payload.can_produce = patch.canProduce;
        if (patch.active !== undefined)     payload.active      = patch.active;

        const { error } = await window.supabaseClient
          .from('branches')
          .update(payload)
          .eq('name', name);
        if (error) throw error;
        await DB.branches.load();
        return true;
      } catch (err) {
        showToast(friendlyError(err, 'Error updating branch'), 'error');
        return false;
      }
    },
  },

  // ─── reference data ────────────────────────────────────────

  /**
   * Refresh the sack-size mirror from the database. Called once at
   * launch so adding a size is a data change, not a code change.
   */
  async loadSackSizes() {
    try {
      const { data, error } = await window.supabaseClient
        .from('sack_sizes')
        .select('product, size_kg, sort')
        .order('product')
        .order('sort');
      if (error) throw error;
      if (!data?.length) return SACK_SIZES;

      const next = {};
      data.forEach(r => {
        (next[r.product] = next[r.product] || []).push(r.size_kg);
      });
      SACK_SIZES = next;
      window.SACK_SIZES = SACK_SIZES;
      return SACK_SIZES;
    } catch (err) {
      // Non-fatal: fall back to the built-in mirror.
      console.error('[loadSackSizes]', err.message);
      return SACK_SIZES;
    }
  },

  // ─── purchases ─────────────────────────────────────────────

  purchases: {

    async getAll(branchFilter, range) {
      try {
        let q = window.supabaseClient
          .from('purchases')
          .select('*')
          .order('entry_time', { ascending: false });
        q = applyDateRange(applyBranchFilter(q, branchFilter), range, 'entry_time');
        const { data, error } = await q;
        if (error) throw error;
        return (data || []).map(mapPurchaseRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading purchases'), 'error');
        return [];
      }
    },

    /** record.qty and record.dirt are kg. There is no ton option. */
    async insert(record) {
      try {
        const { data, error } = await window.supabaseClient
          .from('purchases')
          .insert({
            supplier:       record.supplier ?? null,
            // NULL, never '' - "no phone given" gets one representation.
            phone:          record.phone || null,
            tin:            record.tin ?? null,
            qty_kg:         record.qty,
            price_per_unit: record.price,
            dirt_kg:        record.dirt ?? 0,
            final_qty_kg:   record.finalQty,
            total_rwf:      record.total,
            branch:         record.branch,
            entry_time:     new Date(record.entryTime).toISOString(),
          })
          .select()
          .single();
        if (error) throw error;
        return mapPurchaseRow(data);
      } catch (err) {
        showToast(friendlyError(err, 'Error saving purchase'), 'error');
        return null;
      }
    },
  },

  // ─── productions ───────────────────────────────────────────

  productions: {

    async getAll(branchFilter, range) {
      try {
        let q = window.supabaseClient
          .from('productions')
          .select('*, production_sacks(size_kg, sack_count)')
          .order('production_time', { ascending: false });
        q = applyDateRange(applyBranchFilter(q, branchFilter), range, 'production_time');
        const { data, error } = await q;
        if (error) throw error;
        return (data || []).map(mapProductionRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading productions'), 'error');
        return [];
      }
    },

    /**
     * insert({ product, maize, ratePercent, time, sacks })
     *
     * sacks is keyed by sack size: { 25: 30, 10: 4 }
     *
     * Yield is computed by the database, not here — create_production()
     * derives output and bran from the rate so a tampered client cannot
     * book 100kg of maize as 100kg of semoule plus 32kg of bran. The
     * whole thing (production row + sack rows) is one transaction.
     */
    async insert(record) {
      try {
        const { data, error } = await window.supabaseClient.rpc('create_production', {
          p_product_type:    record.product,
          p_maize_kg:        record.maize,
          p_processing_rate: record.product === 'Semoule'
                               ? record.ratePercent / 100
                               : null,
          p_branch:          record.branch,
          p_production_time: new Date(record.time).toISOString(),
          p_sacks:           record.sacks || {},
        });
        if (error) throw error;
        return { ...mapProductionRow(data), sacks: record.sacks || {} };
      } catch (err) {
        showToast(friendlyError(err, 'Error saving production'), 'error');
        return null;
      }
    },
  },

  // ─── sales ─────────────────────────────────────────────────

  sales: {

    async getAll(branchFilter, range) {
      try {
        let q = window.supabaseClient
          .from('sales')
          .select('*')
          .order('sale_time', { ascending: false });
        q = applyDateRange(applyBranchFilter(q, branchFilter), range, 'sale_time');
        const { data, error } = await q;
        if (error) throw error;
        return (data || []).map(mapSaleRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading sales'), 'error');
        return [];
      }
    },

    /**
     * insert(record)
     *
     * Two shapes, distinguished by record.product:
     *
     *   Semoule / Ordinaire — sold by the sack:
     *     { product, sizeKg, sackCount, pricePerSack, ... }
     *   Bran / Cleaned Maize — sold by weight:
     *     { product, qty, pricePerKg, ... }
     *
     * Prices are entered per sale because they move constantly.
     */
    async insert(record) {
      try {
        const sacked = isSacked(record.product);

        const payload = {
          customer:  record.customer ?? null,
          phone:     record.phone || null,
          product:   record.product,
          branch:    record.branch,
          sale_time: new Date(record.time).toISOString(),
        };

        if (sacked) {
          payload.size_kg     = record.sizeKg;
          payload.sack_count  = record.sackCount;
          payload.qty_kg      = record.sizeKg * record.sackCount;
          payload.unit_price  = record.pricePerSack;
          payload.price_basis = 'sack';
          payload.total_rwf   = record.sackCount * record.pricePerSack;
        } else {
          payload.size_kg     = null;
          payload.sack_count  = null;
          payload.qty_kg      = record.qty;
          payload.unit_price  = record.pricePerKg;
          payload.price_basis = 'kg';
          payload.total_rwf   = record.qty * record.pricePerKg;
        }

        const { data, error } = await window.supabaseClient
          .from('sales')
          .insert(payload)
          .select()
          .single();
        if (error) throw error;
        return mapSaleRow(data);
      } catch (err) {
        showToast(friendlyError(err, 'Error saving sale'), 'error');
        return null;
      }
    },
  },

  // ─── transfers (Main → Rusizi) ─────────────────────────────
  // Two-step by design. Main records what left; Rusizi records what
  // arrived, which may be less. Main's stock falls at dispatch,
  // Rusizi's rises at confirmation, and the gap shows as a variance
  // instead of quietly disappearing.

  transfers: {

    // Every read pulls the lines with the trip, so a dispatch is always
    // a complete delivery note rather than a header needing a second call.
    async getAll() {
      try {
        const { data, error } = await window.supabaseClient
          .from('transfers')
          .select('*, transfer_items(*)')
          .order('dispatched_at', { ascending: false });
        if (error) throw error;
        return (data || []).map(mapTransferRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading transfers'), 'error');
        return [];
      }
    },

    async getPending() {
      try {
        const { data, error } = await window.supabaseClient
          .from('transfers')
          .select('*, transfer_items(*)')
          .eq('status', 'pending')
          .order('dispatched_at', { ascending: true });
        if (error) throw error;
        return (data || []).map(mapTransferRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading transfers'), 'error');
        return [];
      }
    },

    /**
     * insert({ fromBranch, toBranch, plate, note, dispatchedAt, items })
     *
     * items: [{ product, sizeKg, sacks }, ...] - one truck, many loads.
     *
     * Goes through create_transfer() so the whole note is written in one
     * transaction, and so stock is checked on the TOTAL per sack size:
     * two lines of 40 against 70 in stock is 80 requested and must fail,
     * which per-line checking would miss.
     */
    async insert(record) {
      try {
        const { data, error } = await window.supabaseClient.rpc('create_transfer', {
          p_from_branch:   record.fromBranch,
          p_to_branch:     record.toBranch,
          p_plate:         record.plate || null,
          p_note:          record.note || null,
          p_dispatched_at: new Date(record.dispatchedAt).toISOString(),
          p_items:         (record.items || []).map(i => ({
                             product: i.product, size_kg: i.sizeKg, sacks: i.sacks,
                           })),
        });
        if (error) throw error;
        return data;
      } catch (err) {
        showToast(friendlyError(err, 'Error recording dispatch'), 'error');
        return null;
      }
    },

    /**
     * confirm(id, received)
     * received: [{ itemId, sacks }, ...] - what actually arrived, per line.
     * A line left out counts as nothing arrived, not as all of it.
     */
    async confirm(id, received) {
      try {
        const { error } = await window.supabaseClient.rpc('confirm_transfer', {
          p_transfer_id: id,
          p_received:    (received || []).map(r => ({ item_id: r.itemId, sacks: r.sacks })),
        });
        if (error) throw error;
        return true;
      } catch (err) {
        showToast(friendlyError(err, 'Error confirming dispatch'), 'error');
        return false;
      }
    },
  },

  // ─── stock ─────────────────────────────────────────────────
  // Computed by the database (branch_stock), never in the browser,
  // so the inventory screen, the sales form and the enforcement
  // triggers cannot disagree about what is in the store.

  stock: {

    /**
     * get(branch) → {
     *   bulk:  { 'Cleaned Maize': kg, 'Bran': kg },     // Main only
     *   sacks: { Semoule: { 25: n, ... }, Ordinaire: { 50: n, ... } }
     * }
     */
    async get(branch) {
      try {
        const { data, error } = await window.supabaseClient
          .rpc('branch_stock', { p_branch: branch });
        if (error) throw error;

        const out = { bulk: {}, sacks: {} };
        (data || []).forEach(row => {
          if (row.size_kg === null) {
            out.bulk[row.product] = row.kg;
          } else {
            (out.sacks[row.product] = out.sacks[row.product] || {})[row.size_kg] = row.sacks;
          }
        });
        return out;
      } catch (err) {
        showToast(friendlyError(err, 'Error loading stock'), 'error');
        return null;
      }
    },

    /** Stock for every branch the current user is allowed to see. */
    async getVisible() {
      const branches = window.currentUser?.branch === 'All'
        ? branchNames()
        : [window.currentUser?.branch];
      const results = await Promise.all(branches.map(b => DB.stock.get(b)));
      const out = {};
      branches.forEach((b, i) => { if (results[i]) out[b] = results[i]; });
      return out;
    },

    /** Sacks of one product/size at one branch. */
    async sacksInStock(branch, product, sizeKg) {
      try {
        const { data, error } = await window.supabaseClient
          .rpc('sacks_in_stock', {
            p_branch: branch, p_product: product, p_size_kg: sizeKg,
          });
        if (error) throw error;
        return data ?? 0;
      } catch (err) {
        showToast(friendlyError(err, 'Error loading stock'), 'error');
        return null;
      }
    },
  },

  // ─── activityLog ───────────────────────────────────────────

  activityLog: {

    async insert(action, details, branch) {
      try {
        const { error } = await window.supabaseClient
          .from('activity_log')
          .insert({
            action,
            details: details ?? null,
            branch,
          });
        if (error) throw error;
      } catch (err) {
        // Non-fatal — log but don't disrupt the user
        console.error('[activityLog.insert]', err.message);
      }
    },

    /**
     * search(filters) — the Logs screen.
     *
     * Filtering happens in the database so the browser is not pulling
     * the whole table down to search it. RLS still applies: staff see
     * their own branch, admins and managers see everything.
     */
    async search({ from, to, branch, severity, user, text, limit } = {}) {
      try {
        const { data, error } = await window.supabaseClient
          .rpc('search_activity_log', {
            p_from:     from     || null,
            p_to:       to       || null,
            p_branch:   branch   || null,
            p_severity: severity || null,
            p_user:     user     || null,
            p_search:   text     || null,
            p_limit:    limit    || 200,
          });
        if (error) throw error;
        return (data || []).map(row => ({
          id:       row.id,
          action:   row.action,
          details:  row.details,
          branch:   row.branch,
          severity: row.severity,
          entity:   row.entity,
          entityId: row.entity_id,
          snapshot: row.snapshot,
          by:       row.performed_by,
          byName:   row.actor_name,
          byUsername: row.actor_username,
          time:     row.created_at,
        }));
      } catch (err) {
        showToast(friendlyError(err, 'Error loading logs'), 'error');
        return [];
      }
    },

    async getRecent(limit, branchFilter) {
      try {
        let q = window.supabaseClient
          .from('activity_log')
          .select('*, profiles(name, username)')
          .order('created_at', { ascending: false })
          .limit(limit || 20);
        q = applyBranchFilter(q, branchFilter);
        const { data, error } = await q;
        if (error) throw error;
        return (data || []).map(mapActivityRow);
      } catch (err) {
        showToast(friendlyError(err, 'Error loading activity log'), 'error');
        return [];
      }
    },
  },

  // ─── admin ─────────────────────────────────────────────────

  admin: {

    /**
     * deleteRecord(entity, id, reason)
     *
     * The only route to removing an operational record. The raw DELETE
     * policies were withdrawn in migration 004, so this function is the
     * single path — it is admin-only, writes its audit entry in the same
     * transaction as the delete, and rolls the whole thing back if the
     * result would leave any branch holding negative stock.
     *
     * Returns a description of what was removed, or null on failure.
     */
    async deleteRecord(entity, id, reason) {
      try {
        const { data, error } = await window.supabaseClient
          .rpc('admin_delete_record', {
            p_entity: entity, p_id: id, p_reason: reason,
          });
        if (error) throw error;
        return data;
      } catch (err) {
        showToast(friendlyError(err, 'Error deleting record'), 'error');
        return null;
      }
    },
  },

  // ─── passwords ─────────────────────────────────────────────
  // A user changing their OWN password goes straight through Supabase
  // Auth with their own session — no privileged key involved.
  // An admin resetting SOMEONE ELSE'S needs the service_role key, which
  // must never reach a browser, so that goes to an Edge Function.

  passwords: {

    /**
     * changeOwn(newPassword)
     * Works for any signed-in user. Clears the forced-change flag and
     * records it through confirm_own_password_change().
     */
    async changeOwn(newPassword) {
      try {
        const { error } = await window.supabaseClient.auth.updateUser({
          password: newPassword,
        });
        if (error) throw error;

        // If this fails the password IS already changed, so say so
        // rather than implying nothing happened.
        const { error: logErr } =
          await window.supabaseClient.rpc('confirm_own_password_change');
        if (logErr) {
          showToast('Password changed, but it could not be recorded: ' + logErr.message, 'info');
        }
        return true;
      } catch (err) {
        showToast(friendlyError(err, 'Could not change password'), 'error');
        return false;
      }
    },

    /**
     * adminReset(userId, newPassword, note)
     *
     * Admin only, enforced inside the Edge Function against the database
     * rather than against anything this client sends. The target is
     * flagged to choose their own password at next sign-in, so the admin
     * never keeps working knowledge of a live password.
     */
    async adminReset(userId, newPassword, note) {
      try {
        const { data, error } = await window.supabaseClient.functions.invoke(
          'admin-reset-password',
          { body: { userId, newPassword, note: note || null } }
        );

        // A non-2xx reply arrives as FunctionsHttpError with the body
        // still readable — dig the real message out rather than showing
        // the generic "Edge Function returned a non-2xx status code".
        if (error) {
          let msg = error.message;
          try {
            const body = await error.context?.json?.();
            if (body?.error) msg = body.error;
          } catch { /* keep the generic message */ }

          if (/Failed to send|FunctionsFetchError|not found|404/i.test(msg)) {
            throw new Error(
              'The password-reset function is not deployed yet. Reset it from '
              + 'Supabase Dashboard -> Authentication -> Users instead, or deploy it '
              + '(see supabase/functions/admin-reset-password/README.md).'
            );
          }
          throw new Error(msg);
        }

        if (data?.warning) showToast(data.warning, 'info');
        return data;
      } catch (err) {
        showToast(friendlyError(err, 'Could not reset password'), 'error');
        return null;
      }
    },
  },

  // ─── users (profiles) ──────────────────────────────────────

  users: {

    async getAll() {
      try {
        const { data, error } = await window.supabaseClient
          .from('profiles')
          .select('*')
          .order('created_at', { ascending: true });
        if (error) throw error;
        return data || [];
      } catch (err) {
        showToast(friendlyError(err, 'Error loading users'), 'error');
        return [];
      }
    },

    async toggleActive(id, currentStatus) {
      try {
        const { error } = await window.supabaseClient
          .from('profiles')
          .update({ active: !currentStatus })
          .eq('id', id);
        if (error) throw error;
        return true;
      } catch (err) {
        showToast(friendlyError(err, 'Error updating user'), 'error');
        return false;
      }
    },

    /**
     * updateRoleBranch(id, role, branch)
     *
     * Admins and managers only — enforced by the profiles RLS policy and
     * the guard_profile_update() trigger, which also blocks a manager from
     * granting or revoking the admin role.
     *
     * This is how a newly signed-up account (which always starts as an
     * inactive staff member on Main) gets its real role and branch.
     */
    async updateRoleBranch(id, role, branch) {
      try {
        const { error } = await window.supabaseClient
          .from('profiles')
          .update({ role, branch })
          .eq('id', id);
        if (error) throw error;
        return true;
      } catch (err) {
        showToast(friendlyError(err, 'Error updating user'), 'error');
        return false;
      }
    },

    /**
     * create(userData)
     *
     * TODO: Full user creation (auth + profile) requires the SERVICE ROLE KEY
     * which must NEVER be in frontend code.
     *
     * Current workaround (two steps done manually):
     *   1. Admin creates the auth user in Supabase Dashboard →
     *      Authentication → Users → Add User (email: username@kerya.com)
     *   2. handle_new_user() creates the profile as an INACTIVE staff
     *      member. The admin then sets the real role and branch from the
     *      Users screen and activates the account.
     *      (The trigger no longer reads role/branch from user metadata —
     *      that was a privilege-escalation hole. See migrations/001.)
     *
     * Future improvement: a Supabase Edge Function that accepts user data,
     * uses the service_role key server-side, and is called via
     * supabaseClient.functions.invoke('create-user', { body: userData })
     */
    async create(userData) {
      try {
        const { data, error } = await window.supabaseClient
          .from('profiles')
          .upsert({
            id:       userData.id,       // UUID from auth user (from Dashboard)
            name:     userData.name,
            username: userData.username,
            role:     userData.role,
            branch:   userData.branch,
            active:   userData.active ?? true,
          })
          .select()
          .single();
        if (error) throw error;
        return data;
      } catch (err) {
        showToast(friendlyError(err, 'Error creating user profile'), 'error');
        return null;
      }
    },
  },
};

// Expose globally so script.js can use it
window.DB                = DB;
window.SACK_SIZES        = SACK_SIZES;
window.SACKED_PRODUCTS   = SACKED_PRODUCTS;
window.BULK_PRODUCTS     = BULK_PRODUCTS;
window.BRANCHES          = BRANCHES;
window.productsForBranch = productsForBranch;
window.isSacked          = isSacked;
window.branchByName      = branchByName;
window.branchCanProduce  = branchCanProduce;
window.branchNames       = branchNames;
window.DEFAULT_PROCESSING_RATE = DEFAULT_PROCESSING_RATE;
