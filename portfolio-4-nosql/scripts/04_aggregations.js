// =====================================================================
// Portfolio 4: NoSQL and advanced data models
// 04_aggregations.js  Aggregation pipelines for Portfolio 2's reporting
//                     questions, on the larger data left by 03_indexes.js:
//                       A1 monthly totals by type (Portfolio 2 Q2)
//                       A2 top merchants, last 30 days (Q3), from the
//                          merchant snapshot and again with $lookup
//                       A3 inactive customers, an anti-join (Q4)
//                       A4 running balance on a statement (Q5b)
//                       A5 the KYC fields that vary by document type,
//                          from the embedded arrays
//
// Run from the repo root, after 03_indexes.js (see SETUP.md for loading
// MONGODB_URI):
//   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/04_aggregations.js
//
// Read-only: it changes nothing, so it can be run any number of times.
// Each pipeline prints its result, then its plan, the keys and documents
// it examined and its server time from explain("executionStats").
// Exits with code 1 if a check fails or the larger data is missing.
// =====================================================================

if (db.getName() !== 'proclus') {
  print(`Connected to database "${db.getName()}", expected "proclus": put /proclus at the end of MONGODB_URI.`);
  quit(1);
}
if (db.transactions.countDocuments() < 190000) {
  print('The larger data is not loaded: run 03_indexes.js first.');
  quit(1);
}

let failures = 0;
function banner(title) {
  print('');
  print('== ' + title + ' ' + '='.repeat(Math.max(3, 66 - title.length)));
}
function check(label, ok) {
  print((ok ? 'ok    ' : 'FAIL  ') + label);
  if (!ok) failures++;
}

// The plan and the work done, from explain("executionStats"), wherever
// the server put them (top level, or under $cursor / $lookup stages).
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
    out.push(node.stage === 'IXSCAN' ? `IXSCAN ${node.indexName}` : node.stage);
    node = node.inputStage || (node.inputStages && node.inputStages[0]);
  }
  return out.join(' <- ');
}
function explainLine(coll, pipeline) {
  const e = db.getCollection(coll).explain('executionStats').aggregate(pipeline);
  const stats = findKey(e, 'executionStats').executionStats;
  print(`   explain: ${stageChain(findKey(e, 'queryPlanner').queryPlanner.winningPlan)}; ` +
        `keys examined ${stats.totalKeysExamined}, documents examined ${stats.totalDocsExamined}; ` +
        `pipeline ${e.executionTimeMillisEstimate !== undefined ? e.executionTimeMillisEstimate : stats.executionTimeMillis} ms`);
  // A $lookup reports its own work per stage.
  (e.stages || []).filter(s => s.$lookup).forEach(s =>
    print(`   explain: $lookup into ${s.$lookup.from}: ${s.totalDocsExamined} documents and ${s.totalKeysExamined} keys examined, ` +
          `indexes used ${JSON.stringify(s.indexesUsed)}, ${s.executionTimeMillisEstimate} ms`));
}

const lagos = s => new Date(s + '+01:00');
const lagosMonth = d => new Date(d.getTime() + 3600000).toISOString().slice(0, 7);
const credits = ['funding', 'transfer_in', 'reversal'];
// +amount for a credit, -amount for a debit, as Portfolio 2's CASE.
const signedAmount = { $cond: [{ $in: ['$transaction_type', credits] }, '$amount', { $multiply: ['$amount', -1] }] };

print(`MongoDB ${db.version()}; transactions ${db.transactions.countDocuments()}, wallets ${db.wallets.countDocuments()}, ` +
      `customers ${db.customers.countDocuments()}, merchants ${db.merchants.countDocuments()}`);

banner('A1. Monthly totals by type, July-September 2026 (Portfolio 2 Q2)');
// SQL: SELECT date_trunc('month', created_at), transaction_type, count(*),
//      sum(amount) FROM transactions WHERE status = 'completed' AND
//      created_at in Q3 GROUP BY 1, 2 ORDER BY 1, 2
const a1 = [
  { $match: { status: 'completed', created_at: { $gte: lagos('2026-07-01T00:00:00'), $lt: lagos('2026-10-01T00:00:00') } } },
  { $group: { _id: { month: { $dateTrunc: { date: '$created_at', unit: 'month', timezone: 'Africa/Lagos' } },
                     type: '$transaction_type' },
              row_count: { $sum: 1 }, total_ngn: { $sum: '$amount' } } },
  { $sort: { '_id.month': 1, '_id.type': 1 } }
];
const a1Rows = db.transactions.aggregate(a1).toArray();
print('   month    transaction_type     rows        total_ngn');
a1Rows.forEach(r => print(`   ${lagosMonth(r._id.month)}  ${r._id.type.padEnd(17)} ${String(r.row_count).padStart(6)}  ${r.total_ngn.toString().padStart(15)}`));
explainLine('transactions', a1);
// Transfers move money between wallets, so out and in must match, month
// by month, apart from the one reversed transfer in the Portfolio 1 data
// (its money went back to the sender as a reversal, not to the receiver).
const byKey = Object.fromEntries(a1Rows.map(r => [lagosMonth(r._id.month) + ' ' + r._id.type, r]));
const sep = byKey['2026-09 transfer_out'], sepIn = byKey['2026-09 transfer_in'], sepRev = byKey['2026-09 reversal'];
check(`September: transfer_out ${sep.total_ngn} = transfer_in ${sepIn.total_ngn} + reversal ${sepRev.total_ngn}`,
      Number(sep.total_ngn.toString()) === Number(sepIn.total_ngn.toString()) + Number(sepRev.total_ngn.toString()));

banner('A2. Top 10 merchants by money received, 9 September - 8 October 2026 (Q3)');
// Portfolio 2 joins transactions to merchants. Here each payment carries
// a snapshot of its merchant, so the pipeline groups without a join.
const window30 = { $gte: lagos('2026-09-09T00:00:00'), $lt: lagos('2026-10-09T00:00:00') };
const a2 = [
  { $match: { transaction_type: 'merchant_payment', status: 'completed', created_at: window30 } },
  { $group: { _id: '$merchant.merchant_id', business_name: { $first: '$merchant.business_name' },
              category: { $first: '$merchant.category' }, payments: { $sum: 1 }, total_ngn: { $sum: '$amount' } } },
  { $sort: { total_ngn: -1 } },
  { $limit: 10 }
];
const a2Rows = db.transactions.aggregate(a2).toArray();
print('   id  business_name             category        payments       total_ngn');
a2Rows.forEach(r => print(`   ${String(r._id).padStart(2)}  ${r.business_name.padEnd(25)} ${r.category.padEnd(15)} ${String(r.payments).padStart(8)}  ${r.total_ngn.toString().padStart(14)}`));
explainLine('transactions', a2);
// The same report the relational way: group by merchant_id only, then
// $lookup the merchant's current name and category, as Portfolio 2 joins.
const a2lookup = [
  { $match: { transaction_type: 'merchant_payment', status: 'completed', created_at: window30 } },
  { $group: { _id: '$merchant.merchant_id', payments: { $sum: 1 }, total_ngn: { $sum: '$amount' } } },
  { $sort: { total_ngn: -1 } },
  { $limit: 10 },
  { $lookup: { from: 'merchants', localField: '_id', foreignField: '_id', as: 'm' } },
  { $set: { business_name: { $first: '$m.business_name' }, category: { $first: '$m.category' } } },
  { $unset: 'm' }
];
const a2LookupRows = db.transactions.aggregate(a2lookup).toArray();
print('-- the same report with $lookup into merchants (current names):');
explainLine('transactions', a2lookup);
check('snapshot and $lookup give the same 10 merchants, names, counts and totals (no merchant has been renamed)',
      JSON.stringify(a2Rows) === JSON.stringify(a2LookupRows.map(r => ({ _id: r._id, business_name: r.business_name,
        category: r.category, payments: r.payments, total_ngn: r.total_ngn }))));

banner('A3. Inactive customers: no ledger entry since 11 July 2026, top 20 by balance (Q4)');
// NOT EXISTS becomes a $lookup that looks for at most one recent entry
// per wallet, and a $match that keeps customers where every look-up came
// back empty. The inner $lookup uses {wallet_id, created_at} from 03.
const since = lagos('2026-07-11T00:00:00');
const a3 = [
  { $match: { status: 'active' } },
  { $lookup: { from: 'wallets', localField: '_id', foreignField: 'customer_id', as: 'wallets',
      pipeline: [
        { $lookup: { from: 'transactions', localField: '_id', foreignField: 'wallet_id', as: 'recent',
            pipeline: [{ $match: { created_at: { $gte: since } } }, { $limit: 1 }, { $project: { _id: 1 } }] } },
        { $project: { balance: 1, recent: 1 } }] } },
  { $match: { wallets: { $ne: [] }, 'wallets.recent': { $not: { $elemMatch: { $exists: true } } } } },
  { $project: { first_name: 1, last_name: 1, email: 1, kyc_tier: 1, wallets: { $size: '$wallets' },
                balance_held: { $sum: '$wallets.balance' } } },
  { $sort: { balance_held: -1, _id: 1 } },
  { $limit: 20 }
];
const a3Rows = db.customers.aggregate(a3).toArray();
print('   id  name                     email                              tier  wallets   balance_held');
a3Rows.forEach(r => print(`   ${String(r._id).padStart(2)}  ${(r.first_name + ' ' + r.last_name).padEnd(24)} ${r.email.padEnd(34)} ${String(r.kyc_tier).padStart(4)}  ` +
                          `${String(r.wallets).padStart(7)}  ${r.balance_held.toString().padStart(13)}`));
explainLine('customers', a3);
// Cross-check one row the slow, obvious way.
if (a3Rows.length) {
  const wids = db.wallets.find({ customer_id: a3Rows[0]._id }).toArray().map(w => w._id);
  const recent = db.transactions.countDocuments({ wallet_id: { $in: wids }, created_at: { $gte: since } });
  check(`cross-check: customer ${a3Rows[0]._id}'s wallets [${wids}] have ${recent} entries since 11 July`, recent === 0);
}

banner('A4. Running balance on a statement: wallet 2026, September 2026 (Q5b)');
// $setWindowFields is the window function: a running sum over the
// wallet's completed entries in time order, from the first entry to the
// current one. The month is cut out afterwards, as in Portfolio 2, because
// the balance after an entry depends on every earlier entry.
const a4 = [
  { $match: { wallet_id: 2026, status: 'completed' } },
  { $setWindowFields: { sortBy: { created_at: 1, _id: 1 },
                        output: { balance_after: { $sum: signedAmount, window: { documents: ['unbounded', 'current'] } } } } },
  { $match: { created_at: { $gte: lagos('2026-09-01T00:00:00'), $lt: lagos('2026-10-01T00:00:00') } } },
  { $project: { _id: 0, created_at: 1, reference: 1, transaction_type: 1, amount: 1, balance_after: 1 } }
];
const a4Rows = db.transactions.aggregate(a4).toArray();
print('   created_at (UTC)   reference          type                 amount  balance_after');
a4Rows.forEach(r => print(`   ${r.created_at.toISOString().slice(0, 16)}Z  ${r.reference.padEnd(18)} ${r.transaction_type.padEnd(16)} ` +
                          `${r.amount.toString().padStart(11)}  ${r.balance_after.toString().padStart(13)}`));
explainLine('transactions', a4);
// The balance after the wallet's last entry must equal the stored balance.
const last = db.transactions.aggregate([a4[0], a4[1], { $sort: { created_at: -1, _id: -1 } }, { $limit: 1 }]).toArray()[0];
const stored = db.wallets.findOne({ _id: 2026 }).balance;
check(`running balance after wallet 2026's last entry (${last.balance_after}) equals its stored balance (${stored})`,
      last.balance_after.toString() === stored.toString());

banner('A5. KYC documents: which fields each type carries (embedded arrays)');
// The varying KYC fields, counted from the data rather than claimed: the
// embedded documents are unwound and each field's presence is counted.
// In Portfolio 1 these are nullable columns; here they are simply absent.
const a5 = [
  { $unwind: '$kyc_documents' },
  { $group: { _id: '$kyc_documents.document_type', documents: { $sum: 1 },
              verified: { $sum: { $cond: [{ $eq: ['$kyc_documents.status', 'verified'] }, 1, 0] } },
              with_expiry_date: { $sum: { $cond: [{ $ifNull: ['$kyc_documents.expiry_date', false] }, 1, 0] } },
              with_reviewed_at: { $sum: { $cond: [{ $ifNull: ['$kyc_documents.reviewed_at', false] }, 1, 0] } },
              customers: { $addToSet: '$_id' } } },
  { $set: { customers: { $size: '$customers' } } },
  { $sort: { documents: -1, _id: 1 } }
];
const a5Rows = db.customers.aggregate(a5).toArray();
print('   document_type    documents  verified  with expiry_date  with reviewed_at  customers');
a5Rows.forEach(r => print(`   ${r._id.padEnd(16)} ${String(r.documents).padStart(9)} ${String(r.verified).padStart(9)} ` +
                          `${String(r.with_expiry_date).padStart(17)} ${String(r.with_reviewed_at).padStart(17)} ${String(r.customers).padStart(10)}`));
explainLine('customers', a5);
const tiers = db.customers.aggregate([
  { $group: { _id: '$kyc_tier', customers: { $sum: 1 }, avg_documents: { $avg: { $size: '$kyc_documents' } } } },
  { $sort: { _id: 1 } }]).toArray();
tiers.forEach(t => print(`   tier ${t._id}: ${t.customers} customers, ${t.avg_documents.toFixed(2)} KYC documents on average`));
check('only passports and driving licences carry an expiry date',
      a5Rows.every(r => r.with_expiry_date === 0 || ['passport', 'drivers_licence'].includes(r._id)));
const kycTotal = a5Rows.reduce((n, r) => n + r.documents, 0);
check(`${kycTotal} KYC documents counted (expected 31, all from the Portfolio 1 customers)`, kycTotal === 31);

print('');
print(failures === 0 ? 'All checks passed.' : `${failures} check(s) did not come out as expected.`);
if (failures > 0) quit(1);
