// =====================================================================
// Portfolio 4: NoSQL and advanced data models
// 03_indexes.js  Generates about 200,000 ledger entries, then measures
//                two Portfolio 2 operations with explain("executionStats")
//                before and after compound indexes:
//                  Q1 a wallet statement for one month (a find)
//                  Q2 monthly totals by type, July-September 2026 (an
//                     aggregation pipeline, the Portfolio 2 question)
//
// Run from the repo root (see SETUP.md for loading MONGODB_URI):
//   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/03_indexes.js
//
// Re-runnable: it runs 01_seed.js first, then generates the same data
// every time from a fixed random seed (8103). Takes a few minutes, most
// of it sending the documents to Atlas. Timings change between runs;
// keys and documents examined do not.
//
// Sections
//   1. Generate: 5,000 customers with main wallets, ~50,000 transfers
//      and ~200,000 ledger entries, 1 Oct 2025 - 8 Oct 2026
//   2. Before: explain both queries with only the _id and unique indexes
//   3. Compound indexes
//   4. After: explain both queries again
//   5. Index sizes, and the integrity audits on the larger data
//
// Leaves the large data in place for 04_aggregations.js.
// =====================================================================

load(require('path').join(typeof __dirname !== 'undefined' ? __dirname : 'portfolio-4-nosql/scripts', '01_seed.js'));

print('');
print('#####################################################################');
print('# 03_indexes.js: about 200,000 ledger entries, explain before and after');
print('#####################################################################');

banner('1. Generate the larger data');

// Small seeded random number generator (mulberry32), so every run makes
// the same documents, as setseed(0.8103) did in Portfolio 2.
let rngState = 8103;
function rand() {
  rngState = (rngState + 0x6D2B79F5) | 0;
  let x = Math.imul(rngState ^ (rngState >>> 15), 1 | rngState);
  x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
  return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
}
const pick = a => a[Math.floor(rand() * a.length)];
const between = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
const naira = kobo => NumberDecimal((kobo / 100).toFixed(2));

const firstNames = ['Adebayo', 'Chioma', 'Musa', 'Ngozi', 'Tunde', 'Aisha', 'Emeka', 'Funke', 'Ibrahim', 'Kemi',
                    'Obinna', 'Hauwa', 'Segun', 'Amaka', 'Yusuf', 'Bisi', 'Uche', 'Zainab', 'Femi', 'Nkechi'];
const lastNames = ['Okafor', 'Adeyemi', 'Bello', 'Eze', 'Ogunleye', 'Nwosu', 'Abubakar', 'Olatunji', 'Obi', 'Danjuma',
                   'Akinwale', 'Okonkwo', 'Sani', 'Uche', 'Adebayo', 'Ibrahim', 'Afolabi', 'Nnamdi', 'Bakare', 'Musa'];
const merchantsList = db.merchants.find({ status: 'active' }).sort({ _id: 1 }).toArray();

const N_CUSTOMERS = 5000;
const firstCustomer = 21, firstWallet = 26;          // after the Portfolio 1 sample data
const customers = [], walletIds = [], balance = new Map();
for (let i = 0; i < N_CUSTOMERS; i++) {
  const id = firstCustomer + i, fn = pick(firstNames), ln = pick(lastNames);
  customers.push({ _id: id, first_name: fn, last_name: ln, email: `${fn}.${ln}${id}@example.com`.toLowerCase(),
    phone_number: '+23490' + String(50000000 + id), date_of_birth: new Date(Date.UTC(between(1960, 2006), between(0, 11), between(1, 28))),
    kyc_tier: 1, status: 'active', created_at: new Date('2025-09-30T09:00:00Z'), kyc_documents: [], beneficiaries: [] });
  walletIds.push(firstWallet + i);
  balance.set(firstWallet + i, 0);                  // kobo, kept exact as integers
}

// Ledger entries, one day at a time, busier as the year goes on.
// Funding when a wallet is low, otherwise a transfer or a merchant
// payment that the balance can cover, so no balance goes below zero.
const ledger = [], transfers = [];
let ledgerId = 48, transferId = 13;                 // after the Portfolio 1 ids
const start = Date.UTC(2025, 9, 1), days = 373;     // 1 Oct 2025 - 8 Oct 2026 (Lagos dates)
for (let d = 0; d < days; d++) {
  const dayStart = start + d * 86400000 - 3600000; // midnight Lagos = 23:00 UTC the day before
  const ymd = new Date(dayStart + 3600000).toISOString().slice(2, 10).replace(/-/g, '');
  const events = Math.round(260 + d * 0.9 + rand() * 60);
  const times = Array.from({ length: events }, () => dayStart + between(6 * 3600, 23 * 3600) * 1000).sort((a, b) => a - b);
  let n = 0;
  const ref = prefix => prefix + ymd + String(++n).padStart(5, '0');
  for (const t of times) {
    const at = new Date(t), w = pick(walletIds), bal = balance.get(w), roll = rand();
    if (bal < 500000 || roll < 0.2) {               // under NGN 5,000, or one in five: a top-up
      const amt = between(10, 400) * 50000;         // NGN 5,000 - 200,000
      balance.set(w, bal + amt);
      ledger.push({ _id: ledgerId++, reference: ref('TXN'), wallet_id: w, transaction_type: 'funding', amount: naira(amt),
                    status: 'completed', narration: 'Bank transfer top-up', created_at: at });
    } else if (roll < 0.55) {                       // a transfer to another wallet
      let to = pick(walletIds); if (to === w) to = w === walletIds[0] ? w + 1 : w - 1;
      const amt = Math.min(bal, between(10, 1000) * 10000);   // NGN 1,000 - 100,000
      const id = transferId++, reference = ref('TRF');
      balance.set(w, bal - amt); balance.set(to, balance.get(to) + amt);
      transfers.push({ _id: id, reference, sender_wallet_id: w, receiver_wallet_id: to, amount: naira(amt),
                       narration: 'Transfer', status: 'completed', created_at: at, processed_at: at });
      const leg = { transfer: { transfer_id: id, reference }, amount: naira(amt), status: 'completed', narration: 'Transfer', created_at: at };
      ledger.push(Object.assign({ _id: ledgerId++, reference: ref('TXN'), wallet_id: w, transaction_type: 'transfer_out' }, leg));
      ledger.push(Object.assign({ _id: ledgerId++, reference: ref('TXN'), wallet_id: to, transaction_type: 'transfer_in' }, leg));
    } else {                                        // a merchant payment; about 3% fail and move no money
      const m = pick(merchantsList), amt = Math.min(bal, between(200, 6000) * 250 + between(0, 1) * 50);
      const failed = rand() < 0.03;
      if (!failed) balance.set(w, bal - amt);
      ledger.push({ _id: ledgerId++, reference: ref('TXN'), wallet_id: w, transaction_type: 'merchant_payment', amount: naira(amt),
                    status: failed ? 'failed' : 'completed',
                    merchant: { merchant_id: m._id, business_name: m.business_name, category: m.category },
                    narration: 'Payment', created_at: at });
    }
  }
}
// The wallets are written last, with the balance the ledger arrived at.
const wallets = walletIds.map((id, i) => ({ _id: id, customer_id: firstCustomer + i, wallet_number: String(7000000000 + id),
  wallet_type: 'main', balance: naira(balance.get(id)), status: 'active', created_at: new Date('2025-09-30T09:05:00Z') }));

function insertInBatches(coll, docs) {
  for (let i = 0; i < docs.length; i += 10000) db.getCollection(coll).insertMany(docs.slice(i, i + 10000), { ordered: false });
  return db.getCollection(coll).countDocuments();
}
const t0 = Date.now();
print(`customers     ${insertInBatches('customers', customers)} documents`);
print(`wallets       ${insertInBatches('wallets', wallets)} documents`);
print(`transfers     ${insertInBatches('transfers', transfers)} documents`);
print(`transactions  ${insertInBatches('transactions', ledger)} documents`);
print(`(generated and sent to Atlas in ${Math.round((Date.now() - t0) / 1000)} s; time varies with the connection)`);
check(`about 200,000 ledger entries: ${db.transactions.countDocuments()}`, db.transactions.countDocuments() >= 190000);
db.transactions.aggregate([{ $group: { _id: '$transaction_type', n: { $sum: 1 } } }, { $sort: { _id: 1 } }])
  .forEach(g => print(`   ${g._id.padEnd(17)} ${String(g.n).padStart(7)}`));

// ---------------------------------------------------------------------
// The two operations, as in Portfolio 2.
// Q1: the statement for wallet 2026 for September 2026 (Lagos time).
// Q2: completed money by month and type, July-September 2026.
// ---------------------------------------------------------------------
const STATEMENT_WALLET = 2026;
const q1 = {
  filter: { wallet_id: STATEMENT_WALLET, created_at: { $gte: new Date('2026-09-01T00:00:00+01:00'), $lt: new Date('2026-10-01T00:00:00+01:00') } },
  sort: { created_at: 1 }
};
const q2 = [
  { $match: { status: 'completed',
              created_at: { $gte: new Date('2026-07-01T00:00:00+01:00'), $lt: new Date('2026-10-01T00:00:00+01:00') } } },
  { $group: { _id: { month: { $dateTrunc: { date: '$created_at', unit: 'month', timezone: 'Africa/Lagos' } },
                     type: '$transaction_type' },
              row_count: { $sum: 1 }, total_ngn: { $sum: '$amount' } } },
  { $sort: { '_id.month': 1, '_id.type': 1 } }
];

// The executionStats part of an explain, wherever the server put it, and
// the winning plan as a chain of stage names, outermost first.
function findKey(o, key) {
  if (!o || typeof o !== 'object') return null;
  if (key in o) return o;
  for (const v of Object.values(o)) { const f = findKey(v, key); if (f) return f; }
  return null;
}
function stageChain(plan) {
  const out = [];
  let node = plan;
  while (node) {
    if (node.queryPlan) node = node.queryPlan;
    let label = node.stage;
    if (node.stage === 'IXSCAN') label += ` ${node.indexName}`;
    out.push(label);
    node = node.inputStage || (node.inputStages && node.inputStages[0]);
  }
  return out.join(' <- ');
}
function median(xs) { const s = xs.slice().sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; }

// Runs explain("executionStats") five times and reports the median
// server time, with the plan and the work done on the last run.
function measure(label, explainFn) {
  const times = [];
  let last;
  for (let i = 0; i < 5; i++) {
    last = explainFn();
    times.push(findKey(last, 'executionStats').executionStats.executionTimeMillis);
  }
  const holder = findKey(last, 'queryPlanner');
  const stats = findKey(last, 'executionStats').executionStats;
  const res = { label, plan: stageChain(holder.queryPlanner.winningPlan), ms: median(times), times,
                keys: stats.totalKeysExamined, docs: stats.totalDocsExamined, returned: stats.nReturned };
  print(`${label}`);
  print(`   plan: ${res.plan}`);
  print(`   keys examined ${res.keys}, documents examined ${res.docs}, returned ${res.returned}`);
  print(`   executionTimeMillis over 5 runs: [${times.join(', ')}], median ${res.ms} ms`);
  return res;
}
const explainQ1 = hint => () => {
  const c = db.transactions.find(q1.filter).sort(q1.sort);
  return (hint ? c.hint(hint) : c).explain('executionStats');
};
const explainQ2 = hint => () => db.transactions.explain('executionStats').aggregate(q2, hint ? { hint } : {});
// $dateTrunc returns Lagos midnight as a UTC instant (23:00 the day
// before), so the month is printed in Lagos time.
const lagosMonth = d => new Date(d.getTime() + 3600000).toISOString().slice(0, 7);
const q2Rows = () => db.transactions.aggregate(q2).toArray()
  .map(r => `${lagosMonth(r._id.month)}  ${r._id.type.padEnd(17)} ${String(r.row_count).padStart(6)}  ${r.total_ngn.toString().padStart(15)}`);

banner('2. Before: no index on the queried fields');
print('Indexes on transactions: ' + db.transactions.getIndexes().map(i => i.name).join(', '));
const before = {
  q1: measure(`Q1 statement: find(${JSON.stringify({ wallet_id: STATEMENT_WALLET })} + September 2026).sort({ created_at: 1 })`, explainQ1()),
  q2: measure('Q2 monthly totals: aggregate [$match status + Jul-Sep 2026, $group month (Africa/Lagos) + type, $sort]', explainQ2())
};
const q2Before = q2Rows();
print('Q2 result:');
print('   month    transaction_type     rows        total_ngn');
q2Before.forEach(r => print('   ' + r));

banner('3. Compound indexes');
// Q1: equality on wallet_id, then the date range, which is also the sort
// order, so no SORT stage is needed. The same index as Portfolio 2's
// transactions_wallet_id_created_at_idx.
db.transactions.createIndex({ wallet_id: 1, created_at: 1 }, { name: 'transactions_wallet_id_created_at_idx' });
// Q2: equality on status, then the date range (equality before range,
// the ESR rule). Then the two fields Q2 groups and sums, so the index
// alone can answer Q2 without reading a single document: a covered
// query, the MongoDB version of Portfolio 2's INCLUDE index.
db.transactions.createIndex({ status: 1, created_at: 1 }, { name: 'transactions_status_created_at_idx' });
db.transactions.createIndex({ status: 1, created_at: 1, transaction_type: 1, amount: 1 },
                            { name: 'transactions_status_created_at_covering_idx' });
db.transactions.getIndexes().forEach(i => print(`   ${i.name.padEnd(46)} ${JSON.stringify(i.key)}`));

banner('4. After: the same queries');
const after = {
  q1: measure('Q1 statement, planner\'s choice', explainQ1()),
  q2: measure('Q2 monthly totals, planner\'s choice', explainQ2()),
  q2plain: measure('Q2 monthly totals, hinted to the {status, created_at} index (no covering fields)',
                   explainQ2('transactions_status_created_at_idx')),
  q2covering: measure('Q2 monthly totals, hinted to the covering index',
                      explainQ2('transactions_status_created_at_covering_idx'))
};
const q2After = q2Rows();
check('Q2 returns the same rows before and after the indexes', JSON.stringify(q2Before) === JSON.stringify(q2After));
check(`Q1 after: an index scan, no SORT stage (${after.q1.plan})`, /IXSCAN/.test(after.q1.plan) && !/SORT/.test(after.q1.plan));
check(`Q1 after: documents examined = documents returned (${after.q1.docs} = ${after.q1.returned})`, after.q1.docs === after.q1.returned);
check(`Q2 with the covering index reads no documents (${after.q2covering.docs} examined)`, after.q2covering.docs === 0);

print('');
print('Summary (median ms over 5 runs of explain; keys / documents examined)');
print('   query                          before                      after');
const row = (l, b, a) => print(`   ${l.padEnd(30)} ${`${b.ms} ms; ${b.keys} / ${b.docs}`.padEnd(27)} ${a.ms} ms; ${a.keys} / ${a.docs}`);
row('Q1 statement', before.q1, after.q1);
row('Q2 planner\'s choice', before.q2, after.q2);
row('Q2 {status, created_at}', before.q2, after.q2plain);
row('Q2 covering index', before.q2, after.q2covering);

banner('5. Index sizes, and the integrity audits on the larger data');
const st = db.transactions.stats();
print(`transactions: ${st.count} documents, ${(st.size / 1048576).toFixed(1)} MB of data, ${(st.storageSize / 1048576).toFixed(1)} MB on disk (compressed)`);
Object.entries(st.indexSizes).forEach(([n, s]) => print(`   ${n.padEnd(46)} ${(s / 1048576).toFixed(1).padStart(6)} MB`));
const b = balanceMismatches();
check(`balance audit: ${b.length} of ${db.wallets.countDocuments()} wallets differ from their ledger total`, b.length === 0);
const l = legMismatches();
check(`transfer audit: ${l.length} of ${db.transactions.countDocuments({ transfer: { $exists: true } })} transfer ledger entries disagree with their transfer`, l.length === 0);

print('');
print(failures === 0 ? 'All checks passed.' : `${failures} check(s) did not come out as expected.`);
if (failures > 0) quit(1);
