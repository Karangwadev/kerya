// ═══════════════════════════════════════════════════════
// KERYA MAIZE — Application logic
// ═══════════════════════════════════════════════════════
// DB and currentUser are set by src/db.js and src/auth.js and
// exposed on window before this script runs.
//
// The product model (see src/db.js and supabase/migrations/002):
//   * Purchases are in kg. Quantity minus waste = cleaned maize.
//   * Milling produces EITHER Semoule OR Ordinaire, never both.
//       Semoule   — processing rate (default 68%); remainder is bran.
//       Ordinaire — a mixture of everything; 100% yield, no bran.
//   * Semoule and Ordinaire are stocked and sold AS SACKS.
//   * Bran and Cleaned Maize are stocked and sold in kg.
//   * Production and purchasing happen at Main. Rusizi sells only
//     what Main has transferred to it and it has confirmed.
// ═══════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════
// AUTH — handled by src/auth.js
// loginUser() and logoutUser() are defined there.
// ═══════════════════════════════════════════════════════

// Convenience alias: the Enter-key listener below calls doLogin()
function doLogin() {
  loginUser(
    document.getElementById('loginUsername').value.trim(),
    document.getElementById('loginPassword').value
  );
}

// ═══════════════════════════════════════════════════════
// APP LAUNCH
// ═══════════════════════════════════════════════════════

// Menus are built per role AND per branch. Rusizi neither buys maize
// nor mills it, so those screens would only offer its staff a way to
// create records the stock model has nowhere to put.
function buildMenu(role, branch) {
  const dashboard = { id: 'dashboard', label: 'Dashboard',  icon: '🏠' };
  const purchase  = { id: 'purchase',  label: 'Purchases',  icon: '📦' };
  const production= { id: 'production',label: 'Production', icon: '⚙️' };
  const sales     = { id: 'sales',     label: 'Sales',      icon: '💰' };
  const transfers = { id: 'transfers', label: 'Transfers',  icon: '🚚' };
  const inventory = { id: 'inventory', label: 'Inventory',  icon: '🏭' };
  const reports   = { id: 'reports',   label: 'Reports',    icon: '📄' };
  const analytics = { id: 'analytics', label: 'Analytics',  icon: '📊' };
  const users     = { id: 'users',     label: 'Users',      icon: '👥' };
  const branches  = { id: 'branches',  label: 'Branches',   icon: '🏢' };
  const logs      = { id: 'logs',      label: 'Activity Log', icon: '🧾' };

  if (role === 'admin') {
    return [{ section: 'Operations' }, dashboard, purchase, production, sales,
            transfers, inventory,
            { section: 'Management' }, reports, analytics, users, branches, logs];
  }
  if (role === 'manager') {
    // Managers can read the log for their own oversight, but cannot
    // delete records — that is admin-only (see migration 004).
    return [{ section: 'Overview' }, dashboard, purchase, production, sales,
            transfers, inventory,
            { section: 'Reports' }, reports, analytics, logs];
  }
  if (role === 'stakeholder') {
    return [{ section: 'Business Intelligence' },
            { id: 'dashboard', label: 'Overview', icon: '🏠' },
            analytics, reports, inventory];
  }

  // Staff see the screens their branch can actually use. A depot has
  // no mill, so buying maize and milling would only let it create
  // records the stock model has nowhere to put.
  const section = { section: branch + ' Branch' };
  return branchCanProduce(branch)
    ? [section, dashboard, purchase, production, sales, transfers, inventory]
    : [section, dashboard, sales, transfers, inventory];
}

const ROLE_LABELS  = { admin: 'Administrator', manager: 'Main Manager', staff: 'Staff', stakeholder: 'Stakeholder' };
const ROLE_CLASSES = { admin: 'role-admin', manager: 'role-manager', staff: 'role-staff', stakeholder: 'role-stakeholder' };

let currentMenu = [];

async function launchApp() {
  // An admin has reset this password: make them choose their own before
  // anything else loads, so an admin-set password cannot stay in use.
  if (currentUser?.mustChangePassword) { showForceChangeScreen(); return; }

  hideForceChangeScreen();
  document.getElementById('loginScreen').style.display = 'none';
  document.getElementById('appShell').style.display = 'block';

  document.getElementById('sidebarUserName').textContent = currentUser.name;
  document.getElementById('sidebarBranch').textContent =
    currentUser.branch === 'All' ? 'All Branches' : currentUser.branch + ' Branch';
  document.getElementById('topbarBranch').textContent =
    currentUser.branch === 'All' ? 'All Branches' : currentUser.branch;

  const rTag = document.getElementById('sidebarRoleTag');
  rTag.textContent = ROLE_LABELS[currentUser.role];
  rTag.className = 'role-tag ' + ROLE_CLASSES[currentUser.role];

  // Drives the .admin-only table columns. Presentation only — the
  // database is what actually refuses a non-admin delete.
  document.body.classList.toggle('is-admin', currentUser.role === 'admin');

  // Branches and sack sizes are reference data in the database, so
  // opening a branch or adding a sack size is a data change rather
  // than a code change. Both must load before the menus and selectors
  // are built, since those are derived from them.
  await Promise.all([DB.branches.load(), DB.loadSackSizes()]);
  populateBranchSelectors();

  currentMenu = buildMenu(currentUser.role, currentUser.branch);
  const navEl = document.getElementById('navMenu');
  navEl.innerHTML = '';
  currentMenu.forEach(item => {
    if (item.section) {
      navEl.innerHTML += `<div class="nav-section-label">${item.section}</div>`;
    } else {
      navEl.innerHTML += `<div class="nav-item" id="nav-${item.id}" onclick="showView('${item.id}')">
        <span class="icon">${item.icon}</span>${item.label}
      </div>`;
    }
  });

  // Branch pickers only appear where there is a genuine choice: the
  // user must span branches, and more than one must be eligible.
  const spansBranches = ['admin', 'manager'].includes(currentUser.role);
  const show = (wrapId, eligible) => {
    const el = document.getElementById(wrapId);
    if (el) el.style.display = (spansBranches && eligible > 1) ? 'flex' : 'none';
  };
  show('s_branchWrap', branchNames().length);
  show('f_branchWrap', branchNames({ producingOnly: true }).length);
  show('p_branchWrap', branchNames({ producingOnly: true }).length);

  // Prefill dates
  const now = new Date().toISOString().slice(0, 16);
  ['f_entryTime', 'p_time', 's_time', 't_time'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.value = now;
  });

  document.getElementById('p_rate').value = DEFAULT_PROCESSING_RATE;

  initReportPeriodControls();
  onSaleBranchChange();       // populate the product list for the default branch
  onTransferProductChange();  // populate transfer sack sizes

  updateClock();
  setInterval(updateClock, 1000);

  const firstView = currentMenu.find(m => m.id);
  if (firstView) showView(firstView.id);
}

/**
 * Fill every branch <select> from the branches table. Called at launch
 * and again whenever the Branches screen changes something, so opening
 * a branch takes effect without a reload.
 */
function populateBranchSelectors() {
  const all       = branchNames();
  const producing = branchNames({ producingOnly: true });
  const opt = (v, label) => `<option value="${v}">${label || v}</option>`;

  const fill = (id, names, keep) => {
    const el = document.getElementById(id);
    if (!el) return;
    const previous = el.value;
    el.innerHTML = (keep || []).map(k => opt(k.value, k.label)).join('')
                 + names.map(n => opt(n)).join('');
    if ([...el.options].some(o => o.value === previous)) el.value = previous;
  };

  fill('s_branch',     all);
  fill('f_branch',     producing);
  fill('p_branch',     producing);
  // A branch-scoped user can only ever dispatch from their own branch —
  // RLS enforces from_branch = get_my_branch(). Offering the full list
  // made the form claim it was sending from Main while the code used
  // their own branch. Admins and managers span branches, so they choose.
  fill('t_fromBranch', spansAllBranches() ? all : [currentUser.branch]);
  fill('t_toBranch',   all);
  syncTransferDestinations();
  fill('rpt_branch',   all,  [{ value: 'all', label: 'All Branches' }]);
  fill('nu_branch',    all,  [{ value: 'All', label: 'All Branches' }]);
}

// ═══════════════════════════════════════════════════════
// MOBILE NAVIGATION
// ═══════════════════════════════════════════════════════
// Below 768px the sidebar is off-canvas. Nothing used to be able to
// open it, which left phone users stuck on whichever view loaded
// first. showView() closes the drawer after navigating.

function toggleMobileNav() {
  const open = !document.getElementById('sidebar').classList.contains('open');
  setMobileNav(open);
}

function closeMobileNav() { setMobileNav(false); }

function setMobileNav(open) {
  document.getElementById('sidebar').classList.toggle('open', open);
  document.getElementById('navScrim').classList.toggle('open', open);
  document.getElementById('navToggle').setAttribute('aria-expanded', String(open));
  // Stop the page scrolling behind the drawer.
  document.body.style.overflow = open ? 'hidden' : '';
}

function updateClock() {
  const now = new Date();
  document.getElementById('topbarClock').textContent =
    now.toLocaleString('en-RW', { weekday:'short', month:'short', day:'numeric', hour:'2-digit', minute:'2-digit' });
}

// ═══════════════════════════════════════════════════════
// VIEW NAVIGATION
// ═══════════════════════════════════════════════════════
const VIEW_TITLES = {
  dashboard: 'Dashboard', purchase: 'Record Purchase', production: 'Record Production',
  sales: 'Record Sale', transfers: 'Branch Transfers', reports: 'Reports',
  analytics: 'Analytics', users: 'User Management', inventory: 'Inventory',
  branches: 'Branches', logs: 'Activity Log'
};

function showView(id) {
  // The menu is the authority on what this user may open. Without
  // this check a view could be reached from the console even though
  // the role never gets its menu entry. The database is the real
  // guard, but a screen a role cannot use should not open at all.
  if (!currentMenu.some(m => m.id === id)) {
    showToast('You do not have access to that screen', 'error');
    return;
  }

  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const view = document.getElementById('view-' + id);
  const nav  = document.getElementById('nav-' + id);
  if (view) view.classList.add('active');
  if (nav)  nav.classList.add('active');
  document.getElementById('topbarTitle').textContent = VIEW_TITLES[id] || id;

  // Load view data (all async — fire and forget, errors handled inside each function)
  if (id === 'dashboard')   loadDashboard();
  if (id === 'purchase')    loadPurchaseView();
  if (id === 'production')  loadProductionView();
  if (id === 'sales')       loadSalesView();
  if (id === 'transfers')   loadTransfersView();
  if (id === 'analytics')   loadAnalytics();
  if (id === 'users')       loadUsersView();
  if (id === 'inventory')   loadInventory();
  if (id === 'branches')    loadBranchesView();
  if (id === 'logs')        loadLogsView();

  closeMobileNav();   // navigating on a phone should dismiss the drawer
}

/** Only an admin may delete records — migration 004 enforces this too. */
function isAdmin() { return currentUser?.role === 'admin'; }

/**
 * Renders a delete button for a record table row, or an empty cell.
 * The cell is always emitted so header and body counts stay in step;
 * CSS hides the whole column for non-admins.
 */
function deleteCell(entity, id, label) {
  if (!isAdmin()) return '<td class="admin-only">—</td>';
  const safe = String(label).replace(/'/g, '&#39;').replace(/"/g, '&quot;');
  return `<td class="admin-only">
    <button class="btn btn-sm btn-danger"
            onclick="askDelete('${entity}', '${id}', '${safe}')">Delete</button>
  </td>`;
}

// ═══════════════════════════════════════════════════════
// PURCHASE
// ═══════════════════════════════════════════════════════
// Everything is bought, weighed and priced by the kilo — there is no
// ton option. Quantity is the gross delivery; waste is deducted to
// give the cleaned maize weight, and that is what enters stock.
//
// Only a branch with a mill can buy maize — elsewhere the maize could
// never be used. When the user is tied to one branch that is the
// answer; when they span branches the picker decides, falling back to
// the first producing branch.

function purchaseBranch() {
  if (currentUser.branch !== 'All') return currentUser.branch;
  return document.getElementById('f_branch')?.value
      || branchNames({ producingOnly: true })[0]
      || 'Main';
}

function updatePurchasePreview() {
  const qty  = parseFloat(document.getElementById('f_quantity').value) || 0;
  const dirt = parseFloat(document.getElementById('f_dirtRemoved').value) || 0;
  const el   = document.getElementById('f_finalPreview');
  el.value = qty > 0 ? (qty - dirt).toLocaleString() + ' kg' : '—';
}

async function addPurchase() {
  const phone = document.getElementById('f_supplierPhone').value.trim();
  if (!phone) { showToast('Supplier phone is required!', 'error'); return; }

  const qty   = parseFloat(document.getElementById('f_quantity').value) || 0;
  const price = parseFloat(document.getElementById('f_price').value) || 0;
  const dirt  = parseFloat(document.getElementById('f_dirtRemoved').value) || 0;
  const finalQty = qty - dirt;

  if (qty <= 0)   { showToast('Quantity must be greater than zero!', 'error'); return; }
  if (price <= 0) { showToast('Price per kg must be greater than zero!', 'error'); return; }
  if (dirt < 0)   { showToast('Waste removed cannot be negative!', 'error'); return; }
  if (finalQty <= 0) {
    showToast('Waste cannot be greater than or equal to the quantity!', 'error');
    return;
  }

  const branch = purchaseBranch();
  const saved = await DB.purchases.insert({
    supplier: document.getElementById('f_supplier').value.trim(),
    phone,
    tin: document.getElementById('f_supplierTIN').value.trim(),
    qty, price, dirt, finalQty,
    total: finalQty * price,
    branch,
    entryTime: document.getElementById('f_entryTime').value,
  });
  if (!saved) return;

  await logActivity('Purchase recorded',
    `${finalQty.toLocaleString()}kg cleaned maize from ${saved.supplier || 'unnamed supplier'}`,
    branch);
  showToast('✓ Purchase recorded!', 'success');
  clearPurchaseForm();
  await loadPurchaseView();
}

function clearPurchaseForm() {
  ['f_supplier','f_supplierPhone','f_supplierTIN','f_quantity','f_price','f_dirtRemoved']
    .forEach(id => { const el = document.getElementById(id); if (el) el.value = ''; });
  updatePurchasePreview();
}

async function loadPurchaseView() {
  const data = await DB.purchases.getAll(currentUser.branch);
  const tbody = document.getElementById('purchaseRecords');

  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="11" style="text-align:center;color:var(--gray-500);padding:32px">No purchase records yet</td></tr>`;
  } else {
    tbody.innerHTML = data.map(r => `<tr>
      <td>${r.supplier || '—'}</td><td>${r.phone}</td><td>${r.tin || '—'}</td>
      <td>${(r.qty || 0).toLocaleString()}</td>
      <td>${(r.price || 0).toLocaleString()}</td>
      <td>${(r.dirt || 0).toLocaleString()}</td>
      <td><strong>${(r.finalQty || 0).toLocaleString()}</strong></td>
      <td>${(r.total || 0).toLocaleString()}</td>
      <td><span class="badge badge-green">${r.branch}</span></td>
      <td>${formatDate(r.entryTime)}</td>
      ${deleteCell('purchase', r.id,
        `${(r.finalQty||0).toLocaleString()}kg from ${r.supplier || 'unnamed supplier'} on ${formatDate(r.entryTime)}`)}
    </tr>`).join('');
  }

  const today = new Date().toDateString();
  const todayData = data.filter(r => new Date(r.entryTime).toDateString() === today);
  document.getElementById('sumPurchaseToday').textContent =
    todayData.reduce((s, r) => s + (r.finalQty || 0), 0).toLocaleString() + ' kg';
  document.getElementById('sumCostToday').textContent =
    todayData.reduce((s, r) => s + (r.total || 0), 0).toLocaleString();
}

// ═══════════════════════════════════════════════════════
// PRODUCTION
// ═══════════════════════════════════════════════════════
// One product per run. Semoule carries a processing rate and throws
// off bran; Ordinaire is a mixture of everything, so it has neither.
// Yield is recomputed server-side in create_production() — what is
// shown here is a preview, not the authority.

function productionBranch() {
  if (currentUser.branch !== 'All') return currentUser.branch;
  return document.getElementById('p_branch')?.value
      || branchNames({ producingOnly: true })[0]
      || 'Main';
}

let selectedProductType = null;

function selectProductType(product) {
  selectedProductType = product;

  document.querySelectorAll('#p_productChoice .product-option').forEach(btn => {
    btn.classList.toggle('selected', btn.dataset.product === product);
  });

  document.getElementById('p_formBody').style.display = 'block';
  document.getElementById('p_outputLabel').textContent = product;

  // Ordinaire separates nothing out: no rate to set, no bran to show.
  const isSemoule = product === 'Semoule';
  document.getElementById('p_rateWrap').style.display = isSemoule ? 'flex' : 'none';
  document.getElementById('p_branItem').style.display = isSemoule ? 'flex' : 'none';
  document.getElementById('p_sackLabel').textContent  = `Step 3 — ${product} sacks packed`;

  renderSackInputs();
  updateProductionPreview();
}

function renderSackInputs() {
  const sizes = (SACK_SIZES[selectedProductType] || []);
  const tagClass = selectedProductType === 'Semoule' ? 'semoule-tag' : 'ordinaire-tag';
  document.getElementById('p_sackInputs').innerHTML = sizes.map(size => `
    <div class="form-field">
      <label class="sack-label">
        <span class="sack-size-tag ${tagClass}">${size} kg</span>
        ${selectedProductType} ${size}kg — Sacks
      </label>
      <input type="number" id="p_sack_${size}" placeholder="0 sacks" min="0" step="1"
             oninput="updateProductionPreview()">
      <span class="hint">1 sack = ${size} kg</span>
    </div>
  `).join('');
}

function readSackInputs() {
  const sacks = {};
  (SACK_SIZES[selectedProductType] || []).forEach(size => {
    const n = parseInt(document.getElementById('p_sack_' + size)?.value) || 0;
    if (n > 0) sacks[size] = n;
  });
  return sacks;
}

function computeYield() {
  const maize = parseFloat(document.getElementById('p_maizeProcessed').value) || 0;
  if (selectedProductType === 'Semoule') {
    const rate   = parseFloat(document.getElementById('p_rate').value) || 0;
    const output = Math.round(maize * rate / 100);
    return { maize, rate, output, bran: maize - output };
  }
  // Ordinaire: a mixture of everything, so all of it comes out.
  return { maize, rate: null, output: maize, bran: 0 };
}

function updateProductionPreview() {
  const y = computeYield();
  document.getElementById('p_outputKg').textContent = y.output.toLocaleString() + ' kg';
  document.getElementById('p_branKg').textContent   = y.bran.toLocaleString() + ' kg';

  // Reconcile what was packed against what was milled.
  const sacks  = readSackInputs();
  const packed = Object.entries(sacks).reduce((s, [size, n]) => s + (size * n), 0);
  const panel  = document.getElementById('p_sackReconcile');

  if (!y.output || !packed) {
    panel.className = 'reconcile-panel';
    panel.textContent = '';
    return;
  }
  const diff = y.output - packed;
  if (packed > y.output) {
    panel.className = 'reconcile-panel error';
    panel.textContent = `Sacks add up to ${packed.toLocaleString()}kg but only `
      + `${y.output.toLocaleString()}kg of ${selectedProductType} was produced — `
      + `${(-diff).toLocaleString()}kg too many.`;
  } else if (diff > 0) {
    panel.className = 'reconcile-panel warn';
    panel.textContent = `${packed.toLocaleString()}kg packed of ${y.output.toLocaleString()}kg `
      + `produced — ${diff.toLocaleString()}kg left loose (not counted as sack stock).`;
  } else {
    panel.className = 'reconcile-panel ok';
    panel.textContent = `All ${packed.toLocaleString()}kg packed into sacks.`;
  }
}

async function addProduction() {
  if (!selectedProductType) { showToast('Choose Semoule or Ordinaire first!', 'error'); return; }

  const y = computeYield();
  if (y.maize <= 0) { showToast('Maize processed must be greater than zero!', 'error'); return; }

  if (selectedProductType === 'Semoule' && (y.rate <= 0 || y.rate > 100)) {
    showToast('Processing rate must be between 1 and 100%!', 'error');
    return;
  }

  const sacks  = readSackInputs();
  const packed = Object.entries(sacks).reduce((s, [size, n]) => s + (size * n), 0);
  if (!packed) { showToast('Enter at least one sack!', 'error'); return; }
  if (packed > y.output) {
    showToast(`Sacks add up to ${packed.toLocaleString()}kg but only ${y.output.toLocaleString()}kg was produced!`, 'error');
    return;
  }

  // Pre-flight stock check — check_production_stock() is the real guard.
  const branch = productionBranch();
  const stock = await DB.stock.get(branch);
  const available = stock?.bulk?.['Cleaned Maize'];
  if (available !== undefined && y.maize > available) {
    showToast(`Not enough cleaned maize at ${branch}: only ${available.toLocaleString()}kg in store`, 'error');
    return;
  }

  const saved = await DB.productions.insert({
    product:     selectedProductType,
    maize:       y.maize,
    ratePercent: y.rate,
    branch,
    time:        document.getElementById('p_time').value,
    sacks,
  });
  if (!saved) return;

  await logActivity('Production recorded',
    `${y.maize.toLocaleString()}kg maize → ${y.output.toLocaleString()}kg ${selectedProductType}`
      + (y.bran ? ` + ${y.bran.toLocaleString()}kg bran` : ''),
    branch);
  showToast('✓ Production recorded!', 'success');

  resetProductionForm();
  await loadProductionView();
}

function resetProductionForm() {
  document.getElementById('p_maizeProcessed').value = '';
  document.getElementById('p_rate').value = DEFAULT_PROCESSING_RATE;
  renderSackInputs();
  updateProductionPreview();
}

async function loadProductionView() {
  const data = await DB.productions.getAll(currentUser.branch);

  const totals = { maize: 0, Semoule: 0, Ordinaire: 0, bran: 0 };
  data.forEach(r => {
    totals.maize += r.maize || 0;
    totals.bran  += r.bran || 0;
    totals[r.product] = (totals[r.product] || 0) + (r.output || 0);
  });

  document.getElementById('productionSummaryGrid').innerHTML = `
    <div class="stat-card amber">
      <div class="label">Maize Processed</div>
      <div class="value">${totals.maize.toLocaleString()} kg</div><div class="icon-bg">🌽</div>
    </div>
    <div class="stat-card green">
      <div class="label">Semoule Produced</div>
      <div class="value">${totals.Semoule.toLocaleString()} kg</div><div class="icon-bg">🌾</div>
    </div>
    <div class="stat-card amber">
      <div class="label">Ordinaire Produced</div>
      <div class="value">${totals.Ordinaire.toLocaleString()} kg</div><div class="icon-bg">🌽</div>
    </div>
    <div class="stat-card blue">
      <div class="label">Bran Produced</div>
      <div class="value">${totals.bran.toLocaleString()} kg</div><div class="icon-bg">🌿</div>
    </div>`;

  const tbody = document.getElementById('productionRecords');
  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--gray-500);padding:32px">No production records yet</td></tr>`;
    return;
  }
  tbody.innerHTML = data.map(r => {
    const badge = r.product === 'Semoule' ? 'badge-green' : 'badge-amber';
    const sackList = Object.entries(r.sacks || {})
      .sort((a, b) => b[0] - a[0])
      .map(([size, n]) => `${n} × ${size}kg`).join(', ') || '—';
    return `<tr>
      <td><span class="badge ${badge}">${r.product}</span></td>
      <td><strong>${(r.maize || 0).toLocaleString()}</strong></td>
      <td>${r.rate === null || r.rate === undefined ? '—' : Math.round(r.rate * 1000) / 10 + '%'}</td>
      <td>${(r.output || 0).toLocaleString()}</td>
      <td>${(r.bran || 0).toLocaleString()}</td>
      <td>${sackList}</td>
      <td>${formatDate(r.time)}</td>
      ${deleteCell('production', r.id,
        `${(r.maize||0).toLocaleString()}kg maize → ${(r.output||0).toLocaleString()}kg ${r.product} on ${formatDate(r.time)}`)}
    </tr>`;
  }).join('');
}

// ═══════════════════════════════════════════════════════
// SALES
// ═══════════════════════════════════════════════════════
// Semoule and Ordinaire are sold by the sack: pick a size, a count,
// and the price for that sack today. Bran and Cleaned Maize are sold
// by weight. Prices are entered every time because they move.

function saleBranch() {
  return currentUser.branch === 'All'
    ? (document.getElementById('s_branch')?.value || 'Main')
    : currentUser.branch;
}

function onSaleBranchChange() {
  const branch = saleBranch();
  const select = document.getElementById('s_product');
  const products = productsForBranch(branch);
  const previous = select.value;

  select.innerHTML = products.map(p => `<option value="${p}">${p}</option>`).join('');
  if (products.includes(previous)) select.value = previous;

  onSaleProductChange();
}

async function onSaleProductChange() {
  const product = document.getElementById('s_product').value;
  const sacked  = isSacked(product);

  document.getElementById('s_sackMode').style.display = sacked ? 'block' : 'none';
  document.getElementById('s_kgMode').style.display   = sacked ? 'none'  : 'block';

  if (sacked) {
    const sizes = SACK_SIZES[product] || [];
    const select = document.getElementById('s_sackSize');
    select.innerHTML = sizes.map(s => `<option value="${s}">${s} kg</option>`).join('');
    await onSaleSackSizeChange();
  } else {
    const stock = await DB.stock.get(saleBranch());
    const kg = stock?.bulk?.[product];
    document.getElementById('s_kgStockHint').textContent =
      kg === undefined ? 'Not stocked at this branch' : `${kg.toLocaleString()} kg in stock`;
  }
  updateSalePreview();
}

async function onSaleSackSizeChange() {
  const product = document.getElementById('s_product').value;
  const sizeKg  = parseInt(document.getElementById('s_sackSize').value);
  if (!sizeKg) return;

  const sacks = await DB.stock.sacksInStock(saleBranch(), product, sizeKg);
  document.getElementById('s_sackStockHint').textContent =
    sacks === null ? '—' : `${sacks.toLocaleString()} sacks in stock`;
  updateSalePreview();
}

function readSaleForm() {
  const product = document.getElementById('s_product').value;
  const branch  = saleBranch();

  if (isSacked(product)) {
    const sizeKg       = parseInt(document.getElementById('s_sackSize').value) || 0;
    const sackCount    = parseInt(document.getElementById('s_sackCount').value) || 0;
    const pricePerSack = parseFloat(document.getElementById('s_pricePerSack').value) || 0;
    return {
      product, branch, sacked: true, sizeKg, sackCount, pricePerSack,
      qty: sizeKg * sackCount,
      total: sackCount * pricePerSack,
    };
  }
  const qty        = parseFloat(document.getElementById('s_qty').value) || 0;
  const pricePerKg = parseFloat(document.getElementById('s_price').value) || 0;
  return { product, branch, sacked: false, qty, pricePerKg, total: qty * pricePerKg };
}

function updateSalePreview() {
  const f = readSaleForm();
  document.getElementById('saleTotalPreview').textContent = 'RWF ' + f.total.toLocaleString();
  document.getElementById('saleQtyPreview').textContent = f.sacked
    ? (f.sackCount ? `${f.sackCount} × ${f.sizeKg}kg = ${f.qty.toLocaleString()} kg` : '')
    : (f.qty ? `${f.qty.toLocaleString()} kg` : '');
}

async function addSale() {
  const phone = document.getElementById('s_phone').value.trim();
  if (!phone) { showToast('Customer phone is required!', 'error'); return; }

  const f = readSaleForm();
  const customer = document.getElementById('s_customer').value.trim();
  const time     = document.getElementById('s_time').value;

  if (f.sacked) {
    if (f.sackCount <= 0)    { showToast('Number of sacks must be greater than zero!', 'error'); return; }
    if (f.pricePerSack <= 0) { showToast('Price per sack must be greater than zero!', 'error'); return; }

    // Pre-flight check — check_sale_stock() is the real guard.
    const available = await DB.stock.sacksInStock(f.branch, f.product, f.sizeKg);
    if (available !== null && f.sackCount > available) {
      showToast(`Not enough ${f.product} ${f.sizeKg}kg sacks at ${f.branch}: only ${available} in stock`, 'error');
      return;
    }
  } else {
    if (f.qty <= 0)        { showToast('Quantity must be greater than zero!', 'error'); return; }
    if (f.pricePerKg <= 0) { showToast('Price per kg must be greater than zero!', 'error'); return; }

    const stock = await DB.stock.get(f.branch);
    const available = stock?.bulk?.[f.product];
    if (available === undefined) {
      showToast(`${f.product} is not stocked at ${f.branch}`, 'error');
      return;
    }
    if (f.qty > available) {
      showToast(`Not enough ${f.product} at ${f.branch}: only ${available.toLocaleString()}kg available`, 'error');
      return;
    }
  }

  const saved = await DB.sales.insert({ ...f, customer, phone, time });
  if (!saved) return;

  const detail = f.sacked
    ? `${f.sackCount} × ${f.sizeKg}kg ${f.product} → RWF ${f.total.toLocaleString()}`
    : `${f.qty.toLocaleString()}kg ${f.product} → RWF ${f.total.toLocaleString()}`;
  await logActivity('Sale recorded', detail, f.branch);
  showToast('✓ Sale recorded!', 'success');

  ['s_customer','s_phone','s_sackCount','s_pricePerSack','s_qty','s_price']
    .forEach(id => { const el = document.getElementById(id); if (el) el.value = ''; });

  await onSaleProductChange();   // refresh the stock hint
  await loadSalesView();
}

async function loadSalesView() {
  const data = await DB.sales.getAll(currentUser.branch);
  const tbody = document.getElementById('salesRecords');

  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="10" style="text-align:center;color:var(--gray-500);padding:32px">No sales records yet</td></tr>`;
  } else {
    tbody.innerHTML = data.map(r => `<tr>
      <td>${r.customer || '—'}</td><td>${r.phone}</td>
      <td><span class="badge badge-amber">${r.product}</span></td>
      <td>${r.sackCount ? `${r.sackCount} × ${r.sizeKg}kg` : '—'}</td>
      <td>${(r.qty || 0).toLocaleString()}</td>
      <td>${(r.unitPrice || 0).toLocaleString()}<small>/${r.priceBasis}</small></td>
      <td><strong>${(r.total || 0).toLocaleString()}</strong></td>
      <td><span class="badge badge-green">${r.branch}</span></td>
      <td>${formatDate(r.time)}</td>
      ${deleteCell('sale', r.id,
        `${r.sackCount ? `${r.sackCount} × ${r.sizeKg}kg` : (r.qty||0).toLocaleString()+'kg'} ${r.product} to ${r.customer || 'unnamed customer'} on ${formatDate(r.time)}`)}
    </tr>`).join('');
  }

  const today = new Date().toDateString();
  const todayData = data.filter(r => new Date(r.time).toDateString() === today);
  document.getElementById('sumRevenueToday').textContent =
    todayData.reduce((s, r) => s + (r.total || 0), 0).toLocaleString();
  document.getElementById('sumUnitsSoldToday').textContent =
    todayData.reduce((s, r) => s + (r.qty || 0), 0).toLocaleString() + ' kg';
}

// ═══════════════════════════════════════════════════════
// TRANSFERS (branch → branch)
// ═══════════════════════════════════════════════════════
// Two steps on purpose. The sending branch records what left and its
// stock falls straight away. The receiving branch records what
// actually arrived, which may be fewer sacks, and only then does its
// stock rise. The gap is reported as a variance rather than quietly
// disappearing.

function spansAllBranches() {
  return currentUser.branch === 'All';
}

/**
 * A branch cannot transfer to itself, so the sender is removed from the
 * destination list. Called whenever FROM changes.
 */
function syncTransferDestinations() {
  const from = transferFrom();
  const to   = document.getElementById('t_toBranch');
  if (!to) return;
  const previous = to.value;
  const options = branchNames().filter(n => n !== from);
  to.innerHTML = options.map(n => `<option value="${n}">${n}</option>`).join('')
    || '<option value="">No other branch to send to</option>';
  if (options.includes(previous)) to.value = previous;
}

function onTransferFromChange() {
  syncTransferDestinations();
  onTransferSizeChange();
}

function transferFrom() {
  if (currentUser.branch !== 'All') return currentUser.branch;
  return document.getElementById('t_fromBranch')?.value || branchNames()[0];
}

function canDispatch() {
  // Anyone tied to a branch can send from it; admins and managers
  // can send from any. There is no "only Main dispatches" rule —
  // the stock check on the sending side is what keeps it honest.
  return ['admin', 'manager', 'staff'].includes(currentUser.role);
}

/** Can this user confirm arrivals for a given transfer? */
function canConfirm(transfer) {
  if (['admin', 'manager'].includes(currentUser.role)) return true;
  return currentUser.role === 'staff' && transfer.toBranch === currentUser.branch;
}

function onTransferProductChange() {
  const product = document.getElementById('t_product').value;
  const sizes   = SACK_SIZES[product] || [];
  document.getElementById('t_sackSize').innerHTML =
    sizes.map(s => `<option value="${s}">${s} kg</option>`).join('');
  onTransferSizeChange();
}

async function onTransferSizeChange() {
  const product = document.getElementById('t_product').value;
  const sizeKg  = parseInt(document.getElementById('t_sackSize').value);
  if (!sizeKg) return;
  const from = transferFrom();
  const sacks = await DB.stock.sacksInStock(from, product, sizeKg);
  document.getElementById('t_stockHint').textContent =
    sacks === null ? '—' : `${sacks.toLocaleString()} sacks at ${from}`;
}

async function addTransfer() {
  const product    = document.getElementById('t_product').value;
  const sizeKg     = parseInt(document.getElementById('t_sackSize').value) || 0;
  const sacksSent  = parseInt(document.getElementById('t_sacks').value) || 0;
  const fromBranch = transferFrom();
  const toBranch   = document.getElementById('t_toBranch').value;

  if (!sizeKg)        { showToast('Choose a sack size!', 'error'); return; }
  if (sacksSent <= 0) { showToast('Sacks to send must be greater than zero!', 'error'); return; }
  if (fromBranch === toBranch) {
    showToast('A branch cannot transfer stock to itself!', 'error');
    return;
  }

  const available = await DB.stock.sacksInStock(fromBranch, product, sizeKg);
  if (available !== null && sacksSent > available) {
    showToast(`Not enough ${product} ${sizeKg}kg sacks at ${fromBranch}: only ${available} in stock`, 'error');
    return;
  }

  const saved = await DB.transfers.insert({
    product, sizeKg, sacksSent, fromBranch, toBranch,
    note: document.getElementById('t_note').value.trim(),
    dispatchedAt: document.getElementById('t_time').value,
  });
  if (!saved) return;

  await logActivity(`Stock dispatched to ${toBranch}`,
    `${sacksSent} × ${sizeKg}kg ${product}`, fromBranch);
  showToast(`🚚 Dispatch recorded — awaiting ${toBranch} confirmation`, 'success');

  document.getElementById('t_sacks').value = '';
  document.getElementById('t_note').value  = '';
  await onTransferSizeChange();
  await loadTransfersView();
}

async function confirmTransfer(id, sacksSent, toBranch) {
  const input = document.getElementById('conf_' + id);
  const received = parseInt(input?.value);

  if (isNaN(received) || received < 0) {
    showToast('Enter how many sacks actually arrived', 'error');
    return;
  }
  if (received > sacksSent) {
    showToast(`Cannot receive more than the ${sacksSent} sacks that were sent`, 'error');
    return;
  }

  if (!await DB.transfers.confirm(id, received)) return;

  const variance = sacksSent - received;
  await logActivity('Transfer confirmed',
    `${received} of ${sacksSent} sacks received`
      + (variance ? ` — ${variance} short` : ''),
    toBranch);
  showToast(variance
    ? `✓ Confirmed — ${variance} sack(s) short, recorded as a variance`
    : '✓ Confirmed — all sacks received', variance ? 'info' : 'success');

  await loadTransfersView();
}

async function loadTransfersView() {
  const dispatchCard = document.getElementById('dispatchCard');
  if (dispatchCard) dispatchCard.style.display = canDispatch() ? 'block' : 'none';

  const [pending, all] = await Promise.all([
    DB.transfers.getPending(),
    DB.transfers.getAll(),
  ]);

  // ── Awaiting confirmation ──
  const pendingBody = document.getElementById('pendingTransfers');
  if (!pending.length) {
    pendingBody.innerHTML = `<tr><td colspan="7" style="text-align:center;color:var(--gray-500);padding:32px">Nothing awaiting confirmation</td></tr>`;
  } else {
    pendingBody.innerHTML = pending.map(t => `<tr>
      <td>${formatDate(t.dispatchedAt)}</td>
      <td>${t.fromBranch} → <strong>${t.toBranch}</strong></td>
      <td><span class="badge ${t.product === 'Semoule' ? 'badge-green' : 'badge-amber'}">${t.product}</span></td>
      <td>${t.sizeKg} kg</td>
      <td><strong>${t.sacksSent}</strong></td>
      <td>${t.note || '—'}</td>
      <td>${canConfirm(t) ? `
        <div style="display:flex;gap:6px;align-items:center">
          <input type="number" id="conf_${t.id}" class="inline-select" style="width:82px"
                 min="0" max="${t.sacksSent}" step="1" value="${t.sacksSent}"
                 title="Sacks actually received">
          <button class="btn btn-sm btn-green"
                  onclick="confirmTransfer('${t.id}', ${t.sacksSent}, '${t.toBranch}')">Confirm</button>
        </div>` : `<span style="color:var(--gray-500);font-size:0.8rem">Awaiting ${t.toBranch}</span>`}</td>
    </tr>`).join('');
  }

  // ── History ──
  const historyBody = document.getElementById('transferHistory');
  if (!all.length) {
    historyBody.innerHTML = `<tr><td colspan="10" style="text-align:center;color:var(--gray-500);padding:32px">No transfers yet</td></tr>`;
  } else {
    historyBody.innerHTML = all.map(t => {
      const badge = t.status === 'confirmed' ? 'badge-green'
                  : t.status === 'cancelled' ? 'badge-red' : 'badge-amber';
      const varianceCell = t.variance === null ? '—'
        : t.variance === 0 ? '<span class="badge badge-green">0</span>'
        : `<span class="badge badge-red">−${t.variance}</span>`;
      return `<tr>
        <td>${formatDate(t.dispatchedAt)}</td>
        <td>${t.fromBranch} → ${t.toBranch}</td>
        <td>${t.product}</td>
        <td>${t.sizeKg} kg</td>
        <td>${t.sacksSent}</td>
        <td>${t.sacksReceived === null ? '—' : t.sacksReceived}</td>
        <td>${varianceCell}</td>
        <td><span class="badge ${badge}">${t.status}</span></td>
        <td>${t.confirmedAt ? formatDate(t.confirmedAt) : '—'}</td>
        ${deleteCell('transfer', t.id,
          `${t.sacksSent} × ${t.sizeKg}kg ${t.product}, ${t.fromBranch} → ${t.toBranch} (${t.status})`)}
      </tr>`;
    }).join('');
  }
}

// ═══════════════════════════════════════════════════════
// RECORD DELETION (admin)
// ═══════════════════════════════════════════════════════
// Deleting goes through admin_delete_record(), which writes the audit
// entry in the same transaction as the delete and rolls both back if
// the result would leave any branch holding negative stock. The raw
// DELETE policies were withdrawn in migration 004, so this is the only
// route — there is no way to remove a record without a trace.

let pendingDelete = null;

function askDelete(entity, id, label) {
  if (!isAdmin()) { showToast('Only an admin can delete records', 'error'); return; }
  pendingDelete = { entity, id, label };
  document.getElementById('deleteTarget').textContent = `${entity}: ${label}`;
  document.getElementById('deleteReason').value = '';
  document.getElementById('deleteModal').classList.add('open');
  setTimeout(() => document.getElementById('deleteReason').focus(), 50);
}

async function confirmDelete() {
  if (!pendingDelete) return;
  const reason = document.getElementById('deleteReason').value.trim();
  if (reason.length < 3) {
    showToast('Give a reason — it is stored in the log', 'error');
    return;
  }

  const { entity, id } = pendingDelete;
  const summary = await DB.admin.deleteRecord(entity, id, reason);
  if (!summary) return;   // the DB refused; the toast already explained why

  closeModal('deleteModal');
  pendingDelete = null;
  showToast(`Deleted — ${summary}`, 'success');

  // Refresh whichever screen we are on, plus anything stock-dependent.
  if (entity === 'purchase')   await loadPurchaseView();
  if (entity === 'production') await loadProductionView();
  if (entity === 'sale')       await loadSalesView();
  if (entity === 'transfer')   await loadTransfersView();
}

// ═══════════════════════════════════════════════════════
// ACTIVITY LOG (admin / manager)
// ═══════════════════════════════════════════════════════
// The trace for "something looks wrong — what happened?". Every write
// the app makes is logged, and migration 004 adds database triggers
// for the structural changes the app cannot see (role changes, branch
// changes), so those cannot be made silently either.

let logSearchTimer = null;

function debouncedLogSearch() {
  clearTimeout(logSearchTimer);
  logSearchTimer = setTimeout(loadLogsView, 350);
}

function resetLogFilters() {
  document.getElementById('log_period').value   = '7';
  document.getElementById('log_severity').value = '';
  document.getElementById('log_branch').value   = '';
  document.getElementById('log_user').value     = '';
  document.getElementById('log_search').value   = '';
  loadLogsView();
}

async function populateLogFilters() {
  const branchSel = document.getElementById('log_branch');
  branchSel.innerHTML = '<option value="">All branches</option>'
    + branchNames({ includeInactive: true }).map(n => `<option value="${n}">${n}</option>`).join('');

  const userSel = document.getElementById('log_user');
  const users = await DB.users.getAll();
  userSel.innerHTML = '<option value="">All users</option>'
    + users.map(u => `<option value="${u.id}">${u.name} (${u.username})</option>`).join('');
}

async function loadLogsView() {
  if (!document.getElementById('log_branch').options.length) await populateLogFilters();

  const days = parseInt(document.getElementById('log_period').value);
  let from = null;
  if (days > 0) {
    const d = new Date();
    d.setDate(d.getDate() - days);
    from = d.toISOString();
  }

  const entries = await DB.activityLog.search({
    from,
    branch:   document.getElementById('log_branch').value || null,
    severity: document.getElementById('log_severity').value || null,
    user:     document.getElementById('log_user').value || null,
    text:     document.getElementById('log_search').value.trim() || null,
    limit:    500,
  });

  const counts = { info: 0, warning: 0, critical: 0 };
  entries.forEach(e => { counts[e.severity] = (counts[e.severity] || 0) + 1; });

  document.getElementById('logStats').innerHTML = `
    <div class="stat-card blue"><div class="label">Entries Shown</div>
      <div class="value">${entries.length.toLocaleString()}</div><div class="icon-bg">🧾</div></div>
    <div class="stat-card green"><div class="label">Routine</div>
      <div class="value">${counts.info.toLocaleString()}</div><div class="icon-bg">✓</div></div>
    <div class="stat-card amber"><div class="label">Notable</div>
      <div class="value">${counts.warning.toLocaleString()}</div><div class="icon-bg">⚠</div></div>
    <div class="stat-card red"><div class="label">Critical</div>
      <div class="value">${counts.critical.toLocaleString()}</div><div class="icon-bg">🚨</div></div>`;

  document.getElementById('logCount').textContent =
    entries.length >= 500 ? 'Showing the most recent 500 — narrow the filters to see more'
                          : `${entries.length} entr${entries.length === 1 ? 'y' : 'ies'}`;

  const tbody = document.getElementById('logsTableBody');
  if (!entries.length) {
    tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;color:var(--gray-500);padding:32px">No activity matches these filters</td></tr>`;
    return;
  }

  tbody.innerHTML = entries.map(e => `
    <tr class="${e.severity === 'critical' ? 'row-critical' : ''}">
      <td style="white-space:nowrap">${formatDate(e.time)}</td>
      <td><span class="sev sev-${e.severity}">${
        e.severity === 'info' ? 'routine' : e.severity === 'warning' ? 'notable' : 'critical'
      }</span></td>
      <td>${e.action}</td>
      <td class="log-details">${e.details || '—'}</td>
      <td><span class="badge badge-green">${e.branch}</span></td>
      <td>${e.byName || '—'}${e.byUsername ? ` <small style="color:var(--gray-500)">(${e.byUsername})</small>` : ''}</td>
    </tr>`).join('');
}

// ═══════════════════════════════════════════════════════
// BRANCHES (admin)
// ═══════════════════════════════════════════════════════
// Opening a branch is a data change. Nothing in the code names a
// branch — every selector, menu and stock figure is derived from
// this list.

async function addBranch() {
  const name = document.getElementById('nb_name').value.trim();
  const canProduce = document.getElementById('nb_canProduce').value === 'true';

  if (!name) { showToast('Branch name is required!', 'error'); return; }
  if (name.toLowerCase() === 'all') {
    showToast('"All" is reserved — it means every branch on a user profile', 'error');
    return;
  }
  if (branchByName(name)) { showToast(`${name} already exists`, 'error'); return; }

  const saved = await DB.branches.create({ name, canProduce });
  if (!saved) return;

  await logActivity('Branch opened',
    `${name} (${canProduce ? 'production site' : 'sales depot'})`, name);
  showToast(`🏢 ${name} opened`, 'success');

  document.getElementById('nb_name').value = '';
  populateBranchSelectors();
  await loadBranchesView();
}

async function setBranchActive(name, active) {
  if (!await DB.branches.update(name, { active })) return;
  await logActivity(active ? 'Branch reopened' : 'Branch closed', name, name);
  showToast(`${name} ${active ? 'reopened' : 'closed'}`, 'success');
  populateBranchSelectors();
  await loadBranchesView();
}

async function setBranchProduce(name, canProduce) {
  // The guard_branch_update() trigger refuses to strip production
  // from a branch still holding cleaned maize, so a failure here is
  // informative rather than silent.
  if (!await DB.branches.update(name, { canProduce })) {
    await loadBranchesView();   // revert the dropdown
    return;
  }
  await logActivity('Branch type changed',
    `${name} → ${canProduce ? 'production site' : 'sales depot'}`, name);
  showToast(`${name} is now a ${canProduce ? 'production site' : 'sales depot'}`, 'success');
  populateBranchSelectors();
  await loadBranchesView();
}

async function loadBranchesView() {
  const branches = DB.branches.getAll();
  const tbody = document.getElementById('branchesTableBody');

  // Summarise each branch so an admin can see what closing one would strand.
  const stocks = await Promise.all(branches.map(b => DB.stock.get(b.name)));

  tbody.innerHTML = branches.map((b, i) => {
    const s = stocks[i];
    let summary = '—';
    if (s) {
      const parts = [];
      Object.entries(s.bulk).forEach(([product, kg]) => {
        if (kg) parts.push(`${kg.toLocaleString()}kg ${product}`);
      });
      const sackTotal = Object.values(s.sacks)
        .flatMap(sizes => Object.values(sizes))
        .reduce((a, n) => a + n, 0);
      if (sackTotal) parts.push(`${sackTotal.toLocaleString()} sacks`);
      summary = parts.join(' · ') || 'Empty';
    }
    return `<tr>
      <td><strong>${b.name}</strong></td>
      <td>
        <select class="inline-select" onchange="setBranchProduce('${b.name}', this.value === 'true')">
          <option value="true"${b.canProduce ? ' selected' : ''}>Production site</option>
          <option value="false"${!b.canProduce ? ' selected' : ''}>Sales depot</option>
        </select>
      </td>
      <td><span class="badge ${b.active ? 'badge-green' : 'badge-red'}">${b.active ? 'Open' : 'Closed'}</span></td>
      <td>${summary}</td>
      <td>
        <button class="btn btn-sm ${b.active ? 'btn-danger' : 'btn-green'}"
                onclick="setBranchActive('${b.name}', ${!b.active})">
          ${b.active ? 'Close' : 'Reopen'}
        </button>
      </td>
    </tr>`;
  }).join('');
}

// ═══════════════════════════════════════════════════════
// DASHBOARD
// ═══════════════════════════════════════════════════════
async function loadDashboard() {
  const branch = currentUser.branch;
  const [purchases, productions, sales] = await Promise.all([
    DB.purchases.getAll(branch),
    DB.productions.getAll(branch),
    DB.sales.getAll(branch),
  ]);

  const totalRev   = sales.reduce((s, r) => s + (r.total || 0), 0);
  const totalMaize = purchases.reduce((s, r) => s + (r.finalQty || 0), 0);
  const semoule    = productions.filter(r => r.product === 'Semoule')
                                .reduce((s, r) => s + (r.output || 0), 0);
  const ordinaire  = productions.filter(r => r.product === 'Ordinaire')
                                .reduce((s, r) => s + (r.output || 0), 0);

  document.getElementById('dashGreeting').textContent = `Good day, ${currentUser.name.split(' ')[0]} 👋`;
  document.getElementById('dashSubtitle').textContent =
    `${ROLE_LABELS[currentUser.role]} · ${currentUser.branch === 'All' ? 'All Branches' : currentUser.branch + ' Branch'}`;

  document.getElementById('dashStats').innerHTML = `
    <div class="stat-card green"><div class="label">Total Revenue</div><div class="value">RWF ${(totalRev/1000).toFixed(1)}K</div><div class="sub">All time</div><div class="icon-bg">💰</div></div>
    <div class="stat-card amber"><div class="label">Cleaned Maize In</div><div class="value">${(totalMaize/1000).toFixed(1)}T</div><div class="sub">Tonnes</div><div class="icon-bg">📦</div></div>
    <div class="stat-card blue"><div class="label">Semoule Produced</div><div class="value">${(semoule/1000).toFixed(1)}T</div><div class="sub">Tonnes</div><div class="icon-bg">🌾</div></div>
    <div class="stat-card red"><div class="label">Ordinaire Produced</div><div class="value">${(ordinaire/1000).toFixed(1)}T</div><div class="sub">Tonnes</div><div class="icon-bg">🌽</div></div>
  `;

  const logs = await DB.activityLog.getRecent(10, branch);
  document.getElementById('recentActivityBody').innerHTML = logs.map(l => `
    <tr>
      <td>${formatDate(l.time)}</td>
      <td>${l.action}</td>
      <td>${l.details || ''}</td>
      <td><span class="badge badge-green">${l.branch}</span></td>
      <td>${l.byName || l.by || '—'}</td>
    </tr>
  `).join('') || `<tr><td colspan="5" style="text-align:center;color:var(--gray-500);padding:32px">No activity yet</td></tr>`;

  renderSalesChart(sales);
  renderProdChart(productions);
}

// ═══════════════════════════════════════════════════════
// ANALYTICS
// ═══════════════════════════════════════════════════════
async function loadAnalytics() {
  const [purchases, sales] = await Promise.all([
    DB.purchases.getAll('All'),
    DB.sales.getAll('All'),
  ]);

  const names    = branchNames({ includeInactive: true });
  const revenue  = Object.fromEntries(names.map(n => [n, 0]));
  const qty      = Object.fromEntries(names.map(n => [n, 0]));
  const count    = Object.fromEntries(names.map(n => [n, 0]));
  sales.forEach(r => {
    if (!(r.branch in revenue)) { revenue[r.branch] = 0; qty[r.branch] = 0; count[r.branch] = 0; }
    revenue[r.branch] += r.total || 0;
    qty[r.branch]     += r.qty || 0;
    count[r.branch]   += 1;
  });

  const totalRev = Object.values(revenue).reduce((a, n) => a + n, 0);
  const maizeIn  = purchases.reduce((s, r) => s + (r.finalQty || 0), 0);
  const wasteOut = purchases.reduce((s, r) => s + (r.dirt || 0), 0);

  document.getElementById('analyticsStats').innerHTML = `
    <div class="stat-card green"><div class="label">Total Revenue</div><div class="value">RWF ${totalRev.toLocaleString()}</div><div class="icon-bg">💰</div></div>
    <div class="stat-card amber"><div class="label">Cleaned Maize In</div><div class="value">${maizeIn.toLocaleString()} kg</div><div class="icon-bg">📦</div></div>
    <div class="stat-card red"><div class="label">Waste Removed</div><div class="value">${wasteOut.toLocaleString()} kg</div><div class="icon-bg">🗑️</div></div>
    <div class="stat-card blue"><div class="label">Branches Trading</div><div class="value">${branchNames().length}</div><div class="icon-bg">🏢</div></div>
  `;

  document.getElementById('branchSummaryBody').innerHTML = names.map(n => {
    const b = branchByName(n);
    return `<tr>
      <td><strong>${n}</strong>${b?.active === false ? ' <span class="badge badge-red">Closed</span>' : ''}</td>
      <td>${b?.canProduce ? 'Production site' : 'Sales depot'}</td>
      <td>${(count[n] || 0).toLocaleString()}</td>
      <td>${(qty[n] || 0).toLocaleString()} kg</td>
      <td><strong>${(revenue[n] || 0).toLocaleString()}</strong></td>
    </tr>`;
  }).join('') || `<tr><td colspan="5" style="text-align:center;color:var(--gray-500);padding:24px">No branches</td></tr>`;

  renderBranchRevenueChart(names, names.map(n => revenue[n] || 0));
  renderProductChart(sales);
}

// ═══════════════════════════════════════════════════════
// INVENTORY
// ═══════════════════════════════════════════════════════
// Stock comes from the branch_stock() database function — the same
// arithmetic the enforcement triggers use — rather than being
// recomputed here from every purchase, production and sale.
//
// Negative values are shown as-is rather than clamped to zero. An
// earlier version hid them with Math.max(0, …), which is how
// unvalidated sales went unnoticed. A red row is the point.

async function loadInventory() {
  const stock = await DB.stock.getVisible();
  const names = Object.keys(stock);
  const panels = document.getElementById('inventoryPanels');

  if (!names.length) {
    panels.innerHTML = `<div class="card"><div class="card-body">
      <p style="color:var(--gray-500)">No branch stock visible from your account.</p>
    </div></div>`;
    return;
  }

  panels.innerHTML = names.map(name => {
    const s = stock[name];
    const producing = branchCanProduce(name);
    const closed = branchByName(name)?.active === false;

    const bulk = producing ? `
      <div class="prod-section-label">Bulk</div>
      <div class="stat-grid">
        ${bulkCard('Cleaned Maize', s.bulk['Cleaned Maize'] ?? 0, '🌽', 'amber')}
        ${bulkCard('Bran',          s.bulk['Bran'] ?? 0,          '🌿', 'blue')}
      </div>
      <div class="divider"></div>
      <div class="prod-section-label">Packed Sacks</div>` : '';

    return `<div class="card">
      <div class="card-header">
        <h3>📍 ${name} Branch Stock</h3>
        <span class="hint" style="margin:0">
          ${closed ? '⚠ Closed — ' : ''}${producing
            ? 'Buys maize, mills and packs'
            : 'Semoule and Ordinaire only — received by transfer'}
        </span>
      </div>
      <div class="card-body">
        ${bulk}
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Product</th><th>Sack Size</th><th>Sacks in Stock</th><th>Equivalent (kg)</th></tr></thead>
            <tbody>${sackStockRows(s)}</tbody>
          </table>
        </div>
      </div>
    </div>`;
  }).join('');

  // Sacks in flight have left the sender but not yet reached the
  // receiver, so they sit in neither branch's stock.
  const note = document.getElementById('transitNote');
  const pending = await DB.transfers.getPending();
  if (pending.length) {
    const totalSacks = pending.reduce((s, t) => s + t.sacksSent, 0);
    const routes = [...new Set(pending.map(t => `${t.fromBranch} → ${t.toBranch}`))].join(', ');
    note.innerHTML = `<div class="reconcile-panel warn" style="display:block">
      ${totalSacks} sack(s) across ${pending.length} dispatch(es) are in transit
      (${routes}) — they have left the sending branch but have not yet been
      confirmed, so they appear in neither branch's stock.
    </div>`;
  } else {
    note.innerHTML = '';
  }
}

// Negative values are shown as-is rather than clamped to zero. An
// earlier version hid them with Math.max(0, …), which is how
// unvalidated sales went unnoticed. A red card is the point.
function bulkCard(label, value, icon, color) {
  const negative = value < 0;
  return `<div class="stat-card ${negative ? 'red' : color}">
    <div class="label">${label}${negative ? ' ⚠' : ''}</div>
    <div class="value">${(value ?? 0).toLocaleString()} kg</div>
    <div class="icon-bg">${icon}</div>
  </div>`;
}

function sackStockRows(branchStock) {
  const rows = [];
  SACKED_PRODUCTS.forEach(product => {
    (SACK_SIZES[product] || []).forEach(size => {
      const sacks = branchStock.sacks?.[product]?.[size] ?? 0;
      rows.push(`<tr${sacks < 0 ? ' style="background:var(--red-100)"' : ''}>
        <td><span class="badge ${product === 'Semoule' ? 'badge-green' : 'badge-amber'}">${product}</span></td>
        <td>${size} kg</td>
        <td><strong>${sacks.toLocaleString()}</strong>${sacks < 0 ? ' ⚠' : ''}</td>
        <td>${(sacks * size).toLocaleString()} kg</td>
      </tr>`);
    });
  });
  return rows.join('');
}

// ═══════════════════════════════════════════════════════
// USERS
// ═══════════════════════════════════════════════════════
const ALL_ROLES    = ['admin', 'manager', 'staff', 'stakeholder'];
const ALL_BRANCHES = ['Main', 'Rusizi', 'All'];

async function loadUsersView() {
  const users = await DB.users.getAll();
  const tbody = document.getElementById('usersTableBody');

  // Only an admin may change roles — the guard_profile_update() trigger
  // enforces this regardless, but there's no point showing a control that
  // is going to be rejected. Nobody may edit their own row here; that
  // would be the lock-out path the trigger refuses anyway.
  const isAdmin = currentUser.role === 'admin';

  const opts = (values, selected, labels) => values.map(v =>
    `<option value="${v}"${v === selected ? ' selected' : ''}>${labels?.[v] || v}</option>`
  ).join('');

  tbody.innerHTML = users.map(u => {
    const self     = u.id === currentUser.id;
    const editable = isAdmin && !self;
    return `
    <tr>
      <td>${u.name}${self ? ' <span style="color:var(--gray-500);font-size:0.78rem">(you)</span>' : ''}</td>
      <td><code style="background:var(--gray-100);padding:2px 6px;border-radius:4px;font-size:0.82rem">${u.username}</code></td>
      <td>${editable
        ? `<select class="inline-select" onchange="changeUserRole('${u.id}', this.value)">${opts(ALL_ROLES, u.role, ROLE_LABELS)}</select>`
        : `<span class="role-tag ${ROLE_CLASSES[u.role] || ''}">${ROLE_LABELS[u.role] || u.role}</span>`}</td>
      <td>${editable
        ? `<select class="inline-select" onchange="changeUserBranch('${u.id}', this.value)">${opts(ALL_BRANCHES, u.branch)}</select>`
        : u.branch}</td>
      <td><span class="badge ${u.active ? 'badge-green' : 'badge-red'}">${u.active ? 'Active' : 'Inactive'}</span></td>
      <td>${self
        ? '<span style="color:var(--gray-500);font-size:0.8rem">—</span>'
        : `<button class="btn btn-sm ${u.active ? 'btn-danger' : 'btn-green'}" onclick="toggleUser('${u.id}')">
             ${u.active ? 'Deactivate' : 'Activate'}
           </button>`}</td>
      <td class="admin-only">${isAdmin()
        ? `<button class="btn btn-sm btn-outline"
                   onclick="askResetPassword('${u.id}', '${String(u.name).replace(/'/g, '&#39;')}', '${u.username}')">
             Reset
           </button>${u.must_change_password
             ? ' <span class="badge badge-amber" title="Must choose a new password at next sign-in">pending</span>'
             : ''}`
        : '—'}</td>
    </tr>`;
  }).join('');
}

async function changeUserRole(id, role) {
  const users = await DB.users.getAll();
  const u = users.find(x => x.id === id);
  if (!u) return;
  if (await DB.users.updateRoleBranch(id, role, u.branch)) {
    await logActivity('User role changed', `${u.username} → ${ROLE_LABELS[role] || role}`, u.branch);
    showToast(`${u.username} is now ${ROLE_LABELS[role] || role}`, 'success');
  }
  await loadUsersView();   // reload either way, so a rejected change reverts
}

async function changeUserBranch(id, branch) {
  const users = await DB.users.getAll();
  const u = users.find(x => x.id === id);
  if (!u) return;
  if (await DB.users.updateRoleBranch(id, u.role, branch)) {
    await logActivity('User branch changed', `${u.username} → ${branch}`, branch);
    showToast(`${u.username} moved to ${branch}`, 'success');
  }
  await loadUsersView();
}

async function toggleUser(id) {
  const users = await DB.users.getAll();
  const u = users.find(x => x.id === id);
  if (!u) return;
  // Only claim success if the write actually succeeded.
  if (await DB.users.toggleActive(id, u.active)) {
    await logActivity(u.active ? 'User deactivated' : 'User activated', u.username, u.branch);
    showToast(u.active ? 'User deactivated' : 'User activated', 'success');
  }
  await loadUsersView();
}

// ═══════════════════════════════════════════════════════
// PASSWORDS
// ═══════════════════════════════════════════════════════
// Two separate paths, deliberately:
//
//   Changing your OWN password goes straight through Supabase Auth
//   with your own session. No privileged key, nothing to deploy.
//
//   An admin resetting SOMEONE ELSE'S needs the service_role key,
//   which must never reach a browser, so it goes to an Edge Function.
//   The target is then made to choose their own password at next
//   sign-in, so the admin never keeps a working password.

function passwordProblem(pw, confirm) {
  if (!pw || pw.length < 8) return 'Password must be at least 8 characters';
  if (confirm !== undefined && pw !== confirm) return 'The two passwords do not match';
  const weak = ['password', '12345678', 'admin123', 'kerya123', 'qwerty123'];
  if (weak.includes(pw.toLowerCase())) return 'That password is too easy to guess';
  return null;
}

/** Rough guidance only — the real rules are checked before submitting. */
function describeStrength(pw) {
  if (!pw) return null;
  let score = 0;
  if (pw.length >= 8)  score++;
  if (pw.length >= 12) score++;
  if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) score++;
  if (/\d/.test(pw))   score++;
  if (/[^A-Za-z0-9]/.test(pw)) score++;
  if (pw.length < 8) return { cls: 'pw-weak', text: 'Too short — at least 8 characters' };
  if (score <= 2)    return { cls: 'pw-weak', text: 'Weak — mix in capitals, numbers or symbols' };
  if (score === 3)   return { cls: 'pw-ok', text: 'Reasonable' };
  return { cls: 'pw-strong', text: 'Strong' };
}

function updatePasswordStrength() {
  const el = document.getElementById('cp_strength');
  const s = describeStrength(document.getElementById('cp_new').value);
  if (!s) { el.className = 'reconcile-panel'; el.textContent = ''; return; }
  el.className = 'reconcile-panel ' + s.cls;
  el.style.display = 'block';
  el.textContent = s.text;
}

// ── Change my own password ──────────────────────────────
function openChangePasswordModal() {
  document.getElementById('cp_new').value = '';
  document.getElementById('cp_confirm').value = '';
  updatePasswordStrength();
  document.getElementById('changePasswordModal').classList.add('open');
  setTimeout(() => document.getElementById('cp_new').focus(), 50);
}

async function submitOwnPasswordChange() {
  const pw = document.getElementById('cp_new').value;
  const problem = passwordProblem(pw, document.getElementById('cp_confirm').value);
  if (problem) { showToast(problem, 'error'); return; }

  if (!await DB.passwords.changeOwn(pw)) return;
  closeModal('changePasswordModal');
  showToast('Password changed', 'success');
}

// ── Admin resets someone else's ─────────────────────────
let pendingReset = null;

function suggestPassword() {
  // Readable over the phone: no look-alike characters, grouped.
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const pick = n => Array.from({ length: n },
    () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
  document.getElementById('rp_new').value = `${pick(4)}-${pick(4)}-${pick(4)}`;
}

function askResetPassword(userId, name, username) {
  if (!isAdmin()) { showToast('Only an admin can reset passwords', 'error'); return; }
  pendingReset = { userId, name, username };
  document.getElementById('rp_target').textContent = `${name} (${username})`;
  document.getElementById('rp_new').value = '';
  document.getElementById('rp_note').value = '';
  suggestPassword();
  document.getElementById('resetPasswordModal').classList.add('open');
}

async function submitAdminReset() {
  if (!pendingReset) return;
  const pw = document.getElementById('rp_new').value.trim();
  const problem = passwordProblem(pw);
  if (problem) { showToast(problem, 'error'); return; }

  const result = await DB.passwords.adminReset(
    pendingReset.userId, pw, document.getElementById('rp_note').value.trim()
  );
  if (!result) return;   // the toast already explained why

  const who = pendingReset;
  pendingReset = null;
  closeModal('resetPasswordModal');
  // Left on screen so the admin can read it out before it is gone.
  showToast(`Password for ${who.username} is now: ${pw}`, 'success');
  await loadUsersView();
}

// ── Forced change after a reset ─────────────────────────
// launchApp() diverts here when the profile carries the flag, so an
// admin-set password cannot go on being used.
function showForceChangeScreen() {
  document.getElementById('loginScreen').style.display = 'none';
  document.getElementById('appShell').style.display = 'none';
  document.getElementById('forceChangeScreen').classList.add('show');
  document.getElementById('fc_who').textContent =
    `${currentUser.name}, your password was reset by an administrator. Choose a new one to continue.`;
  document.getElementById('fc_new').value = '';
  document.getElementById('fc_confirm').value = '';
  document.getElementById('fc_error').style.display = 'none';
  setTimeout(() => document.getElementById('fc_new').focus(), 50);
}

function hideForceChangeScreen() {
  document.getElementById('forceChangeScreen').classList.remove('show');
}

async function submitForcedChange() {
  const err = document.getElementById('fc_error');
  const pw = document.getElementById('fc_new').value;
  const problem = passwordProblem(pw, document.getElementById('fc_confirm').value);
  if (problem) {
    err.textContent = '⚠ ' + problem;
    err.style.display = 'block';
    return;
  }

  if (!await DB.passwords.changeOwn(pw)) return;

  currentUser.mustChangePassword = false;
  window.currentUser = currentUser;
  hideForceChangeScreen();
  showToast('Password set — welcome back', 'success');
  await launchApp();
}
function openAddUserModal() { document.getElementById('addUserModal').classList.add('open'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); }

function addUser() {
  const name     = document.getElementById('nu_name').value.trim();
  const username = document.getElementById('nu_username').value.trim();
  if (!name || !username) { showToast('Fill all required fields!', 'error'); return; }

  // Creating an auth user requires the service_role key, which must never
  // reach the browser. Until that moves into an Edge Function, the flow is:
  //   1. Supabase Dashboard → Authentication → Users → Add User
  //      (email: <username>@kerya.com)
  //   2. handle_new_user() creates the profile as an INACTIVE staff member
  //   3. Back here: set their role and branch, then Activate
  showToast(
    `Create ${username}@kerya.com in Supabase Dashboard → Auth → Users, ` +
    `then set their role and branch here and activate them.`,
    'info'
  );
  closeModal('addUserModal');
}

// ═══════════════════════════════════════════════════════
// REPORTS
// ═══════════════════════════════════════════════════════

// Kept so the Excel export can rebuild the same figures as sheets
// rather than scraping the rendered HTML.
let lastReport = null;

const MONTH_NAMES = ['January','February','March','April','May','June',
                     'July','August','September','October','November','December'];

/** Fill the year and month pickers. Called once at launch. */
function initReportPeriodControls() {
  const thisYear = new Date().getFullYear();
  const years = [];
  for (let y = thisYear; y >= thisYear - 6; y--) years.push(y);
  document.getElementById('rpt_year').innerHTML =
    years.map(y => `<option value="${y}">${y}</option>`).join('');

  document.getElementById('rpt_month').innerHTML =
    MONTH_NAMES.map((m, i) => `<option value="${i}">${m}</option>`).join('');
  document.getElementById('rpt_month').value = new Date().getMonth();

  const today = new Date().toISOString().slice(0, 10);
  document.getElementById('rpt_from').value = today;
  document.getElementById('rpt_to').value   = today;

  onReportPeriodChange();
}

function onReportPeriodChange() {
  const period = document.getElementById('rpt_period').value;
  const show = (id, on) => {
    document.getElementById(id).style.display = on ? 'flex' : 'none';
  };
  show('rpt_yearWrap',    ['month', 'quarter', 'year'].includes(period));
  show('rpt_quarterWrap', period === 'quarter');
  show('rpt_monthWrap',   period === 'month');
  show('rpt_fromWrap',    period === 'custom');
  show('rpt_toWrap',      period === 'custom');
}

/**
 * Resolve the period controls into a { from, to, label } range.
 *
 * `to` is exclusive — the instant after the last one wanted — so a
 * month boundary needs no "last second of the day" fiddling. Dates are
 * built in local time and converted to instants, so "Q1 2025" means
 * Q1 as experienced here, not in UTC.
 */
function reportRange() {
  const period = document.getElementById('rpt_period').value;
  const year   = parseInt(document.getElementById('rpt_year').value);

  const iso = d => d.toISOString();

  if (period === 'year') {
    return { from: iso(new Date(year, 0, 1)), to: iso(new Date(year + 1, 0, 1)),
             label: String(year) };
  }
  if (period === 'quarter') {
    const q = parseInt(document.getElementById('rpt_quarter').value);
    const startMonth = (q - 1) * 3;
    return { from: iso(new Date(year, startMonth, 1)),
             to:   iso(new Date(year, startMonth + 3, 1)),
             label: `Q${q} ${year}` };
  }
  if (period === 'month') {
    const m = parseInt(document.getElementById('rpt_month').value);
    return { from: iso(new Date(year, m, 1)), to: iso(new Date(year, m + 1, 1)),
             label: `${MONTH_NAMES[m]} ${year}` };
  }
  if (period === 'custom') {
    const fromStr = document.getElementById('rpt_from').value;
    const toStr   = document.getElementById('rpt_to').value;
    if (!fromStr || !toStr) return null;
    const from = new Date(fromStr + 'T00:00:00');
    // "To" is inclusive to the user, so advance a day to make the
    // exclusive bound cover the whole of it.
    const to = new Date(toStr + 'T00:00:00');
    to.setDate(to.getDate() + 1);
    if (to <= from) return null;
    return { from: iso(from), to: iso(to),
             label: `${formatDay(fromStr)} to ${formatDay(toStr)}` };
  }
  return { from: null, to: null, label: 'All time' };
}

function formatDay(isoDate) {
  return new Date(isoDate + 'T00:00:00')
    .toLocaleDateString('en-RW', { year:'numeric', month:'short', day:'numeric' });
}

async function generateReport() {
  const type   = document.getElementById('rpt_type').value;
  const branch = document.getElementById('rpt_branch').value;
  const branchFilter = branch === 'all' ? 'All' : branch;

  const range = reportRange();
  if (!range) {
    showToast('Choose a valid date range — "To" must be on or after "From"', 'error');
    return;
  }

  // Filtered in the database, so a one-quarter report fetches one
  // quarter rather than the whole table.
  const [purchases, productions, sales] = await Promise.all([
    DB.purchases.getAll(branchFilter, range),
    DB.productions.getAll(branchFilter, range),
    DB.sales.getAll(branchFilter, range),
  ]);

  const scopeLabel = branch === 'all' ? 'All Branches' : branch + ' Branch';
  lastReport = { type, branch, scopeLabel, range, purchases, productions, sales };

  const now = new Date().toLocaleDateString('en-RW', { year:'numeric', month:'long', day:'numeric' });
  let html = `<div class="card"><div class="report-masthead">`
    + `<img src="kerya_maize_logo.png" alt="Kerya Maize" class="report-logo">`
    + `<h3>📋 ${type.charAt(0).toUpperCase() + type.slice(1)} Report — ${scopeLabel}</h3>`
    + `<span style="font-size:0.8rem;color:var(--gray-500)">`
    + `<strong>${range.label}</strong> · generated ${now}</span>`
    + `</div><div class="card-body">`;

  if (!purchases.length && !productions.length && !sales.length) {
    html += `<p style="color:var(--gray-500);padding:24px 0">`
      + `No records for ${scopeLabel} in ${range.label}.</p>`;
  }

  if (type === 'full' || type === 'purchase') {
    const t = purchaseTotals(purchases);
    html += `<p style="margin-bottom:12px">`
      + `Purchases: <strong>${purchases.length}</strong> &nbsp; `
      + `Total (Maize and Waste): <strong>${t.gross.toLocaleString()}kg</strong> &nbsp; `
      + `Waste: <strong>${t.waste.toLocaleString()}kg</strong> &nbsp; `
      + `Sub-Total (Maize minus Waste): <strong>${t.net.toLocaleString()}kg</strong> &nbsp; `
      + `Total Cost: <strong>RWF ${t.cost.toLocaleString()}</strong></p>`;
    html += `<table><tr><th>Supplier</th><th>Total (kg)</th><th>Waste (kg)</th>`
      + `<th>Sub-Total (kg)</th><th>Price/kg</th><th>Amount</th><th>Branch</th><th>Date</th></tr>`;
    purchases.forEach(r => html += `<tr>
      <td>${r.supplier || '—'}</td>
      <td>${(r.qty || 0).toLocaleString()}</td>
      <td>${(r.dirt || 0).toLocaleString()}</td>
      <td>${(r.finalQty || 0).toLocaleString()}</td>
      <td>${(r.price || 0).toLocaleString()}</td>
      <td>RWF ${(r.total || 0).toLocaleString()}</td>
      <td>${r.branch}</td><td>${formatDate(r.entryTime)}</td></tr>`);
    html += `<tr style="font-weight:700;background:var(--green-50)">
      <td>TOTAL</td><td>${t.gross.toLocaleString()}</td><td>${t.waste.toLocaleString()}</td>
      <td>${t.net.toLocaleString()}</td><td>—</td>
      <td>RWF ${t.cost.toLocaleString()}</td><td>—</td><td>—</td></tr>`;
    html += '</table>';
  }

  if (type === 'full' || type === 'production') {
    const semoule   = productions.filter(r => r.product === 'Semoule').reduce((s,r) => s + (r.output||0), 0);
    const ordinaire = productions.filter(r => r.product === 'Ordinaire').reduce((s,r) => s + (r.output||0), 0);
    const bran      = productions.reduce((s, r) => s + (r.bran || 0), 0);
    html += `<p style="margin:16px 0 12px">Productions: <strong>${productions.length}</strong> &nbsp; `
      + `Semoule: <strong>${semoule.toLocaleString()}kg</strong> &nbsp; `
      + `Ordinaire: <strong>${ordinaire.toLocaleString()}kg</strong> &nbsp; `
      + `Bran: <strong>${bran.toLocaleString()}kg</strong></p>`;
    html += `<table><tr><th>Product</th><th>Maize In</th><th>Rate</th><th>Output</th>`
      + `<th>Bran</th><th>Sacks</th><th>Time</th></tr>`;
    productions.forEach(r => html += `<tr>
      <td>${r.product}</td>
      <td>${(r.maize || 0).toLocaleString()}kg</td>
      <td>${r.rate ? Math.round(r.rate * 1000) / 10 + '%' : '—'}</td>
      <td>${(r.output || 0).toLocaleString()}kg</td>
      <td>${(r.bran || 0).toLocaleString()}kg</td>
      <td>${sackSummary(r.sacks)}</td>
      <td>${formatDate(r.time)}</td></tr>`);
    html += '</table>';
  }

  if (type === 'full' || type === 'sales') {
    const rev   = sales.reduce((s, r) => s + (r.total || 0), 0);
    const units = sales.reduce((s, r) => s + (r.qty || 0), 0);
    html += `<p style="margin:16px 0 12px">Sales: <strong>${sales.length}</strong> &nbsp; `
      + `Total Quantity: <strong>${units.toLocaleString()}kg</strong> &nbsp; `
      + `Total Revenue: <strong>RWF ${rev.toLocaleString()}</strong></p>`;
    html += `<table><tr><th>Customer</th><th>Product</th><th>Sacks</th><th>Qty (kg)</th>`
      + `<th>Unit Price</th><th>Total</th><th>Branch</th><th>Time</th></tr>`;
    sales.forEach(r => html += `<tr>
      <td>${r.customer || '—'}</td><td>${r.product}</td>
      <td>${r.sackCount ? `${r.sackCount} × ${r.sizeKg}kg` : '—'}</td>
      <td>${(r.qty || 0).toLocaleString()}</td>
      <td>${(r.unitPrice || 0).toLocaleString()}/${r.priceBasis}</td>
      <td>RWF ${(r.total || 0).toLocaleString()}</td>
      <td>${r.branch}</td><td>${formatDate(r.time)}</td></tr>`);
    html += '</table>';
  }

  html += '</div></div>';
  document.getElementById('reportContent').innerHTML = html;
}

function purchaseTotals(purchases) {
  return {
    gross: purchases.reduce((s, r) => s + (r.qty || 0), 0),       // maize and waste
    waste: purchases.reduce((s, r) => s + (r.dirt || 0), 0),
    net:   purchases.reduce((s, r) => s + (r.finalQty || 0), 0),  // maize minus waste
    cost:  purchases.reduce((s, r) => s + (r.total || 0), 0),
  };
}

function sackSummary(sacks) {
  return Object.entries(sacks || {})
    .sort((a, b) => b[0] - a[0])
    .map(([size, n]) => `${n} × ${size}kg`).join(', ') || '—';
}

/** "Kerya_sales_Rusizi_Q1-2025" — scope and period, safe for a filename. */
function reportFileStem() {
  if (!lastReport) return 'Kerya_Report';
  const { type, branch, range } = lastReport;
  const scope  = branch === 'all' ? 'All-Branches' : branch;
  const period = (range.label || 'All-time').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '');
  return `Kerya_${type}_${scope}_${period}`;
}

function downloadReportPDF() {
  const el = document.getElementById('reportContent');
  if (!el.innerHTML) { showToast('Generate a report first!', 'error'); return; }
  html2pdf().set({
    margin: 0.5, filename: reportFileStem() + '.pdf',
    html2canvas: { scale: 2 }, jsPDF: { format: 'letter' }
  }).from(el).save();
}

/**
 * Excel export. Builds sheets from the report data rather than
 * scraping the rendered table, so the numbers stay numbers and
 * remain usable in formulas.
 */
function downloadReportExcel() {
  if (!lastReport) { showToast('Generate a report first!', 'error'); return; }
  if (typeof XLSX === 'undefined') {
    showToast('Excel library failed to load — check your connection', 'error');
    return;
  }

  const { type, scopeLabel, range, purchases, productions, sales } = lastReport;
  const wb = XLSX.utils.book_new();

  // A sheet saying what this file actually is, so a downloaded
  // workbook is still meaningful months later.
  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet([
    { Field: 'Report',    Value: type.charAt(0).toUpperCase() + type.slice(1) },
    { Field: 'Branch',    Value: scopeLabel },
    { Field: 'Period',    Value: range.label },
    { Field: 'Generated', Value: formatDate(new Date().toISOString()) },
    { Field: 'Purchases', Value: purchases.length },
    { Field: 'Productions', Value: productions.length },
    { Field: 'Sales',     Value: sales.length },
  ]), 'Report Info');

  if (type === 'full' || type === 'purchase') {
    const rows = purchases.map(r => ({
      Supplier: r.supplier || '',
      Phone: r.phone || '',
      TIN: r.tin || '',
      'Total (Maize and Waste) kg': r.qty || 0,
      'Waste kg': r.dirt || 0,
      'Sub-Total (Maize minus Waste) kg': r.finalQty || 0,
      'Price per kg (RWF)': r.price || 0,
      'Amount (RWF)': r.total || 0,
      Branch: r.branch,
      Date: formatDate(r.entryTime),
    }));
    const t = purchaseTotals(purchases);
    rows.push({});
    rows.push({
      Supplier: 'TOTAL',
      'Total (Maize and Waste) kg': t.gross,
      'Waste kg': t.waste,
      'Sub-Total (Maize minus Waste) kg': t.net,
      'Amount (RWF)': t.cost,
    });
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), 'Purchases');
  }

  if (type === 'full' || type === 'production') {
    const rows = productions.map(r => ({
      Product: r.product,
      'Maize In kg': r.maize || 0,
      'Processing Rate %': r.rate ? Math.round(r.rate * 1000) / 10 : '',
      'Output kg': r.output || 0,
      'Bran kg': r.bran || 0,
      Sacks: sackSummary(r.sacks),
      Time: formatDate(r.time),
    }));
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), 'Production');
  }

  if (type === 'full' || type === 'sales') {
    const rows = sales.map(r => ({
      Customer: r.customer || '',
      Phone: r.phone || '',
      Product: r.product,
      'Sack Size kg': r.sizeKg || '',
      Sacks: r.sackCount || '',
      'Quantity kg': r.qty || 0,
      'Unit Price (RWF)': r.unitPrice || 0,
      'Priced Per': r.priceBasis,
      'Total (RWF)': r.total || 0,
      Branch: r.branch,
      Time: formatDate(r.time),
    }));
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), 'Sales');
  }

  XLSX.writeFile(wb, reportFileStem() + '.xlsx');
  showToast('✓ Excel file downloaded', 'success');
}

// ═══════════════════════════════════════════════════════
// CHARTS
// ═══════════════════════════════════════════════════════
const chartInstances = {};
function makeChart(id, config) {
  if (chartInstances[id]) chartInstances[id].destroy();
  const ctx = document.getElementById(id);
  if (!ctx) return;
  chartInstances[id] = new Chart(ctx, config);
}

const CHART_DEFAULTS = {
  responsive: true, maintainAspectRatio: false,
  plugins: { legend: { labels: { font: { family: 'DM Sans', size: 12 }, color: '#374151' } } }
};

function getLast7Days() {
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(); d.setDate(d.getDate() - 6 + i);
    return d.toLocaleDateString('en-RW', { month:'short', day:'numeric' });
  });
}

function renderSalesChart(sales) {
  const labels = getLast7Days();
  const data = labels.map((_, i) => {
    const day = new Date(); day.setDate(day.getDate() - 6 + i);
    return sales.filter(r => new Date(r.time).toDateString() === day.toDateString())
                .reduce((s, r) => s + (r.total || 0), 0);
  });
  makeChart('salesChart', {
    type: 'bar',
    data: { labels, datasets: [{ label:'Revenue (RWF)', data, backgroundColor:'#4caf50aa', borderColor:'#2e7d32', borderWidth:2, borderRadius:4 }] },
    options: { ...CHART_DEFAULTS, scales: { y:{beginAtZero:true,grid:{color:'#f3f4f6'}}, x:{grid:{display:false}} } }
  });
}

function renderProdChart(productions) {
  makeChart('prodChart', {
    type: 'doughnut',
    data: {
      labels: ['Semoule', 'Ordinaire', 'Bran'],
      datasets: [{ data: [
        productions.filter(r => r.product === 'Semoule').reduce((s,r) => s + (r.output||0), 0),
        productions.filter(r => r.product === 'Ordinaire').reduce((s,r) => s + (r.output||0), 0),
        productions.reduce((s, r) => s + (r.bran || 0), 0),
      ], backgroundColor: ['#4caf50', '#f59e0b', '#3b82f6'], borderWidth: 0 }]
    },
    options: { ...CHART_DEFAULTS, cutout: '65%' }
  });
}

// Scales to however many branches exist — colours cycle rather than
// being paired to specific branch names.
const BRANCH_COLOURS = ['#2e7d32', '#f59e0b', '#3b82f6', '#8b5cf6', '#ec4899', '#14b8a6'];

function renderBranchRevenueChart(labels, data) {
  makeChart('branchRevenueChart', {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'Revenue (RWF)', data,
        backgroundColor: labels.map((_, i) => BRANCH_COLOURS[i % BRANCH_COLOURS.length]),
        borderRadius: 6
      }]
    },
    options: { ...CHART_DEFAULTS, scales: { y:{beginAtZero:true,grid:{color:'#f3f4f6'}}, x:{grid:{display:false}} } }
  });
}

function renderProductChart(sales) {
  const products = {};
  sales.forEach(r => { products[r.product] = (products[r.product] || 0) + (r.total || 0); });
  const labels = Object.keys(products);
  makeChart('productChart', {
    type: 'bar',
    data: { labels, datasets: [{ label:'Revenue (RWF)', data: labels.map(k => products[k]), backgroundColor:'#3b82f6aa', borderColor:'#1d4ed8', borderWidth:1, borderRadius:4 }] },
    options: { ...CHART_DEFAULTS, indexAxis:'y', scales:{ x:{beginAtZero:true}, y:{grid:{display:false}} } }
  });
}

// renderTrendChart / renderEfficiencyChart were removed with their
// canvases — see the note in the Analytics view in index.html.

// ═══════════════════════════════════════════════════════
// UTILITIES
// ═══════════════════════════════════════════════════════
async function logActivity(action, details, branch) {
  await DB.activityLog.insert(action, details, branch);
}

function showToast(msg, type = 'success') {
  const c = document.getElementById('toastContainer');
  const t = document.createElement('div');
  t.className = `toast toast-${type}`;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => t.remove(), 3500);
}

function formatDate(dt) {
  if (!dt) return '—';
  try {
    return new Date(dt).toLocaleString('en-RW', { year:'numeric', month:'short', day:'numeric', hour:'2-digit', minute:'2-digit' });
  } catch { return dt; }
}

/** CSV export of a rendered table body. */
function exportTable(tbodyId, filename) {
  const tbody = document.getElementById(tbodyId);
  if (!tbody || !tbody.rows.length) { showToast('Nothing to export', 'error'); return; }

  const table = tbody.closest('table');
  const head = [...(table?.tHead?.rows[0]?.cells || [])]
    .map(th => `"${th.innerText.replace(/\s+/g, ' ').trim().replace(/"/g, '""')}"`);

  const rows = [...tbody.rows].map(tr =>
    [...tr.cells].map(td => `"${td.innerText.replace(/\s+/g, ' ').trim().replace(/"/g, '""')}"`).join(',')
  );

  const csv = [head.join(','), ...rows].join('\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

// ═══════════════════════════════════════════════════════
// STARTUP
// ═══════════════════════════════════════════════════════
document.getElementById('loginPassword')
  .addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });

['f_quantity', 'f_dirtRemoved'].forEach(id => {
  document.getElementById(id).addEventListener('input', updatePurchasePreview);
});
['p_maizeProcessed', 'p_rate'].forEach(id => {
  document.getElementById(id).addEventListener('input', updateProductionPreview);
});
document.getElementById('cp_new').addEventListener('input', updatePasswordStrength);

// Enter submits the forced-change screen — it is the only thing on it.
['fc_new', 'fc_confirm'].forEach(id => {
  document.getElementById(id).addEventListener('keydown', e => {
    if (e.key === 'Enter') submitForcedChange();
  });
});

// Restore the Supabase session on page load. restoreSession() is
// defined in src/auth.js and calls launchApp() if one is found.
restoreSession();
