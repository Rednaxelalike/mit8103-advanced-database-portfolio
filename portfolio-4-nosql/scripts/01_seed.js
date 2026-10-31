// =====================================================================
// Portfolio 4: NoSQL and advanced data models
// 01_seed.js  Builds the Proclus document database on Atlas: six
//             collections with their $jsonSchema validators and unique
//             indexes, loaded with the Portfolio 1 sample data from
//             model/documents/, then audited and tested.
//
// Run from the repo root (see SETUP.md for loading MONGODB_URI):
//   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/01_seed.js
//
// Re-runnable: it drops the six collections first, so every run starts
// from the same 153 documents. The connection string must name the
// proclus database; the script refuses to run anywhere else.
//
// Sections
//   1. Collections with validators (model/validators.json)
//   2. Unique indexes: the Portfolio 1 UNIQUE constraints
//   3. Load the documents (model/documents/*.json)
//   4. Counts and the two Portfolio 1 integrity audits, as aggregations
//   5. Tests: what the validators and unique indexes reject (code 121
//      and 11000), and what a document database does not check at all
//   6. Counts and audits again, to show the tests left the data as loaded
//
// Exits with code 1 if any count, audit or test does not come out as
// expected.
// =====================================================================

const fs = require('fs');
const path = require('path');

if (db.getName() !== 'proclus') {
  print(`Connected to database "${db.getName()}", expected "proclus": put /proclus at the end of MONGODB_URI.`);
  quit(1);
}

const scriptDir = typeof __dirname !== 'undefined' ? __dirname : path.resolve('portfolio-4-nosql/scripts');
const modelDir = path.join(scriptDir, '..', 'model');
const validators = JSON.parse(fs.readFileSync(path.join(modelDir, 'validators.json'), 'utf8'));
const collections = ['customers', 'wallets', 'merchants', 'transfers', 'transactions', 'audit_log'];

let failures = 0;
function banner(title) {
  print('');
  print('== ' + title + ' ' + '='.repeat(Math.max(3, 66 - title.length)));
}
function check(label, ok) {
  print((ok ? 'ok    ' : 'FAIL  ') + label);
  if (!ok) failures++;
}

banner(`1. Collections with validators (MongoDB ${db.version()}, replica set ${db.hello().setName})`);

for (const name of collections) {
  db.getCollection(name).drop();
  db.createCollection(name, {
    validator: validators[name],
    validationLevel: 'strict',   // check every insert and every update
    validationAction: 'error'    // reject, do not just log a warning
  });
  print(`created ${name}`);
}

banner('2. Unique indexes (the Portfolio 1 UNIQUE constraints)');

// Each entry: collection, keys, options. The names follow Portfolio 1.
const uniqueIndexes = [
  // Case-insensitive, like Portfolio 2's UNIQUE index on lower(email):
  // strength 2 compares letters without their case.
  ['customers', { email: 1 }, { name: 'customers_email_key', collation: { locale: 'en', strength: 2 } }],
  ['customers', { phone_number: 1 }, { name: 'customers_phone_number_key' }],
  // Embedded documents: unique across customers. Three customers have no
  // KYC documents yet, so the index only covers customers that have one.
  ['customers', { 'kyc_documents.document_type': 1, 'kyc_documents.document_number': 1 },
    { name: 'kyc_documents_number_key',
      partialFilterExpression: { 'kyc_documents.document_number': { $exists: true } } }],
  ['merchants', { cac_number: 1 }, { name: 'merchants_cac_number_key' }],
  ['merchants', { email: 1 }, { name: 'merchants_email_key' }],
  ['wallets', { wallet_number: 1 }, { name: 'wallets_wallet_number_key' }],
  ['wallets', { customer_id: 1, wallet_type: 1 }, { name: 'wallets_one_per_type_key' }],
  ['transfers', { reference: 1 }, { name: 'transfers_reference_key' }],
  ['transactions', { reference: 1 }, { name: 'transactions_reference_key' }],
  // Only ledger entries that belong to a transfer, as in Portfolio 1
  // (where NULL transfer_ids never clash).
  ['transactions', { 'transfer.transfer_id': 1, transaction_type: 1 },
    { name: 'transactions_one_leg_per_type_key',
      partialFilterExpression: { 'transfer.transfer_id': { $exists: true } } }]
];
for (const [coll, keys, options] of uniqueIndexes) {
  db.getCollection(coll).createIndex(keys, Object.assign({ unique: true }, options));
  print(`${coll}.${options.name}  ${JSON.stringify(keys)}`);
}
// Not carried over: beneficiaries_wallet_once_key and
// beneficiaries_nickname_key. A unique index compares different
// documents, never two array elements inside one document, so it cannot
// stop a customer saving the same wallet twice (test 5.4 shows this).

banner('3. Load the documents');

for (const name of collections) {
  // relaxed: false keeps {"$numberDecimal": ...} as Decimal128 and
  // {"$date": ...} as a Date; small integers become 32-bit ints.
  const docs = EJSON.parse(fs.readFileSync(path.join(modelDir, 'documents', name + '.json'), 'utf8'), { relaxed: false });
  const result = db.getCollection(name).insertMany(docs, { ordered: true });
  print(`${name.padEnd(13)} inserted ${Object.keys(result.insertedIds).length}`);
}

// Counts expected from 00_export_p1_documents.sql (the Portfolio 1 rows).
const expected = { customers: 20, wallets: 25, merchants: 12, transfers: 12, transactions: 47, audit_log: 37,
                   kyc_documents: 31, beneficiaries: 18 };

function embeddedCount(field) {
  return db.customers.aggregate([
    { $group: { _id: null, n: { $sum: { $size: '$' + field } } } }
  ]).toArray()[0].n;
}

// The "audit balances" operation: a stored balance must equal completed
// credits minus completed debits. Same rule as the DO block at the end of
// Portfolio 1's 02_sample_data.sql, written as a pipeline with $lookup.
function balanceMismatches() {
  return db.wallets.aggregate([
    { $lookup: {
        from: 'transactions',
        let: { w: '$_id' },
        pipeline: [
          { $match: { $expr: { $eq: ['$wallet_id', '$$w'] }, status: 'completed' } },
          { $group: { _id: null, total: { $sum: {
              $cond: [{ $in: ['$transaction_type', ['funding', 'transfer_in', 'reversal']] },
                      '$amount', { $multiply: ['$amount', -1] }] } } } }
        ],
        as: 'ledger' } },
    { $set: { ledger_balance: { $ifNull: [{ $first: '$ledger.total' }, NumberDecimal('0')] } } },
    { $match: { $expr: { $ne: ['$balance', '$ledger_balance'] } } },
    { $project: { balance: 1, ledger_balance: 1 } }
  ]).toArray();
}

// Every ledger entry of a transfer carries the transfer's amount and the
// right wallet: the receiver for transfer_in, the sender otherwise.
function legMismatches() {
  return db.transactions.aggregate([
    { $match: { transfer: { $exists: true } } },
    { $lookup: { from: 'transfers', localField: 'transfer.transfer_id', foreignField: '_id', as: 't' } },
    { $unwind: '$t' },
    { $match: { $expr: { $or: [
        { $ne: ['$amount', '$t.amount'] },
        { $ne: ['$wallet_id', { $cond: [{ $eq: ['$transaction_type', 'transfer_in'] },
                                        '$t.receiver_wallet_id', '$t.sender_wallet_id'] }] }
    ] } } },
    { $project: { wallet_id: 1, transaction_type: 1, amount: 1 } }
  ]).toArray();
}

function countsAndAudits() {
  for (const name of collections) {
    const n = db.getCollection(name).countDocuments();
    check(`${name.padEnd(13)} ${String(n).padStart(3)} documents (expected ${expected[name]})`, n === expected[name]);
  }
  for (const field of ['kyc_documents', 'beneficiaries']) {
    const n = embeddedCount(field);
    check(`${field.padEnd(13)} ${String(n).padStart(3)} embedded in customers (expected ${expected[field]})`, n === expected[field]);
  }
  const b = balanceMismatches();
  check(`balance audit: ${b.length} of ${db.wallets.countDocuments()} wallets differ from their ledger total`, b.length === 0);
  b.forEach(d => printjson(d));
  const l = legMismatches();
  check(`transfer audit: ${l.length} of ${db.transactions.countDocuments({ transfer: { $exists: true } })} transfer ledger entries disagree with their transfer`, l.length === 0);
  l.forEach(d => printjson(d));
}

banner('4. Counts and integrity audits');
countsAndAudits();

banner('5. Tests');

// A short path to the rule a rejected document broke, from the error's
// errInfo, e.g. "properties > balance > minimum". It follows the first
// unsatisfied rule at each level, and for an allOf names the rule by its
// description in validators.json.
function brokenRule(errInfo) {
  const parts = [];
  let node = errInfo && errInfo.details;
  while (node) {
    const op = node.operatorName;
    if (op && op !== '$jsonSchema' && op !== '$and') parts.push(op);
    if (node.propertyName) parts.push(node.propertyName);
    if (op === 'allOf') { parts.push('"' + node.schemasNotSatisfied[0].description + '"'); break; }
    if (['oneOf', 'anyOf', 'not', '$expr'].includes(op)) break;
    const next = node.details && !Array.isArray(node.details) ? [node.details]
      : Object.values(node).find(v => Array.isArray(v) && v.length && typeof v[0] === 'object');
    node = next ? next[0] : null;
  }
  return parts.join(' > ');
}
const codeNames = { 121: 'DocumentValidationFailure', 11000: 'DuplicateKey' };

let testNo = 0;
function errorOf(fn) {
  try { fn(); return null; } catch (e) { return e; }
}
function errInfoOf(e) {
  return e.errInfo || (e.writeErrors && e.writeErrors[0] && (e.writeErrors[0].err || e.writeErrors[0]).errInfo);
}
// Expect the write to fail with this error code.
function expectError(label, code, fn) {
  testNo++;
  const e = errorOf(fn);
  const got = e ? e.code : 'no error';
  let detail = '';
  if (e && code === 121) detail = '  [' + brokenRule(errInfoOf(e)) + ']';
  if (e && code === 11000) detail = '  [' + (e.message.match(/index: (\S+)/) || [])[1] + ']';
  check(`5.${testNo} ${label}: ${e ? 'rejected with ' + got + ' ' + (codeNames[got] || '') : 'accepted'}${detail}`, got === code);
}
// Expect the write to be accepted, which shows a rule the database does
// not enforce. undo puts the data back.
function expectAccepted(label, fn, undo) {
  testNo++;
  const e = errorOf(fn);
  check(`5.${testNo} ${label}: ${e ? 'rejected with ' + e.code : 'accepted'} (not checked by MongoDB)`, !e);
  if (undo) undo();
}
// A copy of a stored document with some fields changed or removed.
function variant(doc, changes, removed) {
  const d = Object.assign({}, doc, changes || {});
  (removed || []).forEach(f => delete d[f]);
  return d;
}

print('-- Validators: each document breaks one $jsonSchema or $expr rule (expect 121 DocumentValidationFailure)');
// Each base copy is valid and clashes with nothing, so a test fails only
// on the one field it changes. Customer 6 has a main wallet, no savings.
const wallet6 = variant(db.wallets.findOne({ _id: 6 }), { _id: 901, wallet_number: '5999999901', wallet_type: 'savings' });
expectError('wallet with a negative balance', 121, () =>
  db.wallets.insertOne(variant(wallet6, { balance: NumberDecimal('-1.00') })));
expectError('wallet balance stored as a double, not Decimal128', 121, () =>
  db.wallets.insertOne(variant(wallet6, { balance: 5000.5 })));
expectError('overdraft: debit wallet 2 (23,500.00) by 50,000.00', 121, () =>
  db.wallets.updateOne({ _id: 2 }, { $inc: { balance: NumberDecimal('-50000.00') } }));

const transfer1 = variant(db.transfers.findOne({ _id: 1 }), { _id: 901, reference: 'TRF9999999901' });
expectError('transfer to the sending wallet', 121, () =>
  db.transfers.insertOne(variant(transfer1, { receiver_wallet_id: transfer1.sender_wallet_id })));
expectError('transfer processed before it was created', 121, () =>
  db.transfers.insertOne(variant(transfer1, { processed_at: new Date(transfer1.created_at.getTime() - 60000) })));
expectError('failed transfer without a failure_reason', 121, () =>
  db.transfers.insertOne(variant(transfer1, { status: 'failed' })));
expectError('transfer of 0.00', 121, () =>
  db.transfers.insertOne(variant(transfer1, { amount: NumberDecimal('0.00') })));

const payment8 = variant(db.transactions.findOne({ _id: 8 }), { _id: 901, reference: 'TXN9999999901' });
expectError('merchant payment without its merchant', 121, () =>
  db.transactions.insertOne(variant(payment8, {}, ['merchant'])));
expectError('funding entry carrying a merchant', 121, () =>
  db.transactions.insertOne(variant(payment8, { transaction_type: 'funding' })));

const stored6 = db.customers.findOne({ _id: 6 });
const bvn6 = stored6.kyc_documents[0];
const customer6 = variant(stored6, { _id: 901, email: 'test.901@example.com', phone_number: '+2348039999901', kyc_documents: [] });
expectError('BVN with 10 digits', 121, () =>
  db.customers.insertOne(variant(customer6, { kyc_documents: [variant(bvn6, { document_number: '2273058194' })] })));
expectError('BVN with an expiry date', 121, () =>
  db.customers.insertOne(variant(customer6, { kyc_documents: [variant(bvn6, { expiry_date: new Date('2030-01-01') })] })));
expectError('KYC document marked verified with no reviewer', 121, () =>
  db.customers.updateOne({ _id: 6, 'kyc_documents.document_id': 12 }, { $set: { 'kyc_documents.$.status': 'verified' } }));
expectError('KYC tier 4', 121, () =>
  db.customers.insertOne(variant(customer6, { kyc_tier: 4 })));
expectError('customer with a field the model does not have', 121, () =>
  db.customers.insertOne(variant(customer6, { nickname: 'Funmi' })));

const audit1 = variant(db.audit_log.findOne({ _id: 1 }), { _id: 901 });
expectError('audit entry about a document but with no entity_id', 121, () =>
  db.audit_log.insertOne(variant(audit1, {}, ['entity_id'])));

print('-- Unique indexes: each document repeats a key (expect 11000 DuplicateKey)');
expectError('customer email that differs only in case', 11000, () =>
  db.customers.insertOne(variant(customer6, { email: 'Funmi.Adebayo@Example.com' })));
expectError('customer phone number already in use', 11000, () =>
  db.customers.insertOne(variant(customer6, { phone_number: '+2348131000006' })));
expectError('BVN already on another customer (pushed into customer 2)', 11000, () =>
  db.customers.updateOne({ _id: 2 }, { $push: { kyc_documents: variant(bvn6, { document_id: 901 }) } }));
expectError('second main wallet for customer 6', 11000, () =>
  db.wallets.insertOne(variant(wallet6, { wallet_type: 'main' })));
expectError('wallet number already in use', 11000, () =>
  db.wallets.insertOne(variant(wallet6, { wallet_number: db.wallets.findOne({ _id: 6 }).wallet_number })));
expectError('merchant CAC number already in use', 11000, () =>
  db.merchants.insertOne(variant(db.merchants.findOne({ _id: 1 }), { _id: 901, email: 'x@test901.example.com' })));
expectError('transfer reference already in use', 11000, () =>
  db.transfers.insertOne(variant(transfer1, { reference: 'TRF2608150001' })));
expectError('second transfer_out leg for transfer 1', 11000, () =>
  db.transactions.insertOne(variant(db.transactions.findOne({ 'transfer.transfer_id': 1, transaction_type: 'transfer_out' }),
                                    { _id: 901, reference: 'TXN9999999901' })));

print('-- Not enforced: rules Portfolio 1 checks that a document database leaves to the application');
expectAccepted('ledger entry for wallet 999, which does not exist (no foreign key)', () =>
  db.transactions.insertOne(variant(payment8, { wallet_id: 999 })),
  () => db.transactions.deleteOne({ _id: 901 }));

const wallet5 = db.wallets.findOne({ _id: 5 });
let orphaned = 0;
expectAccepted('delete wallet 5 while ledger entries point at it (no ON DELETE RESTRICT)', () => {
  db.wallets.deleteOne({ _id: 5 });
  orphaned = db.transactions.countDocuments({ wallet_id: 5 });
}, () => db.wallets.insertOne(wallet5));
print(`      ${orphaned} ledger entries were left pointing at the deleted wallet; it has been put back`);

const firstBeneficiary = db.customers.findOne({ _id: 6 }).beneficiaries[0];
expectAccepted(`customer 6 saves wallet ${firstBeneficiary.wallet_id} a second time (unique index cannot look inside one array)`, () =>
  db.customers.updateOne({ _id: 6 }, { $push: { beneficiaries: variant(firstBeneficiary, { beneficiary_id: 901 }) } }),
  () => db.customers.updateOne({ _id: 6 }, { $pull: { beneficiaries: { beneficiary_id: 901 } } }));

// The application-side fix for the case above: make the "not saved yet"
// test part of the update's filter, so the check and the write are one
// atomic operation on the document.
testNo++;
const guarded = db.customers.updateOne(
  { _id: 6, 'beneficiaries.wallet_id': { $ne: firstBeneficiary.wallet_id } },
  { $push: { beneficiaries: variant(firstBeneficiary, { beneficiary_id: 901 }) } });
check(`5.${testNo} the same save with the wallet in the update's filter: matched ${guarded.matchedCount}, modified ${guarded.modifiedCount}`,
      guarded.modifiedCount === 0);

banner('6. Counts and integrity audits after the tests');
countsAndAudits();

print('');
print(failures === 0 ? 'All checks passed.' : `${failures} check(s) did not come out as expected.`);
if (failures > 0) quit(1);
