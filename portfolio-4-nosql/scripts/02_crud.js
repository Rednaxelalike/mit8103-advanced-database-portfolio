// =====================================================================
// Portfolio 4: NoSQL and advanced data models
// 02_crud.js  Create, read, update and delete for the Proclus key
//             operations (Portfolio 1 case study), on the documents
//             loaded by 01_seed.js.
//
// Run from the repo root (see SETUP.md for loading MONGODB_URI):
//   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/02_crud.js
//
// Re-runnable: it runs 01_seed.js first, so every run starts from the
// same 153 documents and the same ids. Every time is fixed (31 October
// 2026, Lagos time), so two runs print the same output.
//
// One new customer, Adaobi Chukwu, goes through the key operations:
//   1. Create  open an account: customer with an embedded BVN, main wallet
//   2. Read    the profile in one read; a customer's wallets
//   3. Update  verify KYC; fund the wallet; save a beneficiary
//   4. Money   a transfer as a multi-document transaction, two transfers
//              that abort (insufficient funds, frozen receiver), and a
//              merchant payment
//   5. Read    a wallet statement for a date range
//   6. Delete  remove a beneficiary; close a wallet, which is never deleted
//   7. Counts and the two integrity audits from 01_seed.js
//
// Exits with code 1 if any check does not come out as expected.
// =====================================================================

// Rebuild. 01_seed.js defines path, banner(), check(), failures and the
// audit functions used again in section 7; they share this script's
// global scope.
load(require('path').join(typeof __dirname !== 'undefined' ? __dirname : 'portfolio-4-nosql/scripts', '01_seed.js'));

// The Lagos clock for this script: UTC+1, fixed so the output repeats.
function lagos(hhmm) { return new Date(`2026-10-31T${hhmm}:00+01:00`); }
const TODAY = lagos('00:00');
const ngn = d => 'NGN ' + d.toString();
function balanceOf(walletId) { return db.wallets.findOne({ _id: walletId }).balance; }

// New ids follow on from the highest stored _id, as an identity column
// would. This is safe here because one script writes at a time; a real
// application would use ObjectIds or a counter document updated with
// $inc, so two writers could never pick the same number.
function nextId(coll) { return db.getCollection(coll).find({}, { _id: 1 }).sort({ _id: -1 }).limit(1).next()._id + 1; }
function nextEmbeddedId(field, idField) {
  const r = db.customers.aggregate([{ $unwind: '$' + field }, { $group: { _id: null, m: { $max: '$' + field + '.' + idField } } }]).toArray();
  return (r.length ? r[0].m : 0) + 1;
}

print('');
print('#####################################################################');
print('# 02_crud.js: the key operations for one new customer');
print('#####################################################################');

banner('1. Create: open an account');

// Onboarding rule from the case study: a customer must be 18 or over.
// No validator can compare a date with today, so the application checks
// it before writing anything.
function ageOn(dob, day) {
  let age = day.getUTCFullYear() - dob.getUTCFullYear();
  if (day.getUTCMonth() < dob.getUTCMonth() ||
      (day.getUTCMonth() === dob.getUTCMonth() && day.getUTCDate() < dob.getUTCDate())) age--;
  return age;
}
const minor = new Date('2010-02-14T00:00:00Z');
check(`registration with date of birth 2010-02-14 refused by the application: age ${ageOn(minor, TODAY)} is under 18, nothing written`,
      ageOn(minor, TODAY) < 18);

const customerId = nextId('customers');
const documentId = nextEmbeddedId('kyc_documents', 'document_id');
const dob = new Date('1998-04-22T00:00:00Z');
check(`Adaobi Chukwu, born 1998-04-22, is ${ageOn(dob, TODAY)} on 2026-10-31`, ageOn(dob, TODAY) >= 18);

// One insert creates the customer and the BVN she submitted with it.
// Tier 1 until compliance verifies the BVN.
let r = db.customers.insertOne({
  _id: customerId, first_name: 'Adaobi', last_name: 'Chukwu',
  email: 'adaobi.chukwu@example.com', phone_number: '+2348091000021',
  date_of_birth: dob, kyc_tier: 1, status: 'active', created_at: lagos('09:00'),
  kyc_documents: [{ document_id: documentId, document_type: 'bvn', document_number: '22381940576',
                    status: 'submitted', submitted_at: lagos('09:02') }],
  beneficiaries: []
});
print(`insertOne customers  _id ${r.insertedId} with 1 embedded KYC document (document_id ${documentId})`);

const walletId = nextId('wallets');
r = db.wallets.insertOne({ _id: walletId, customer_id: customerId, wallet_number: '5216039482',
                           wallet_type: 'main', balance: NumberDecimal('0.00'), status: 'active', created_at: lagos('09:03') });
print(`insertOne wallets    _id ${r.insertedId}, wallet_number 5216039482, balance NGN 0.00`);

banner('2. Read: the customer profile');

// Portfolio 1 needs customers JOIN kyc_documents JOIN beneficiaries (or
// three queries) for this screen. Here it is one document.
print(`-- db.customers.findOne({ _id: 5 }): Ibrahim Musa's profile, KYC and beneficiaries in one read`);
printjson(db.customers.findOne({ _id: 5 }, { first_name: 1, last_name: 1, kyc_tier: 1, status: 1,
  'kyc_documents.document_type': 1, 'kyc_documents.status': 1, 'kyc_documents.reviewed_by': 1, beneficiaries: 1 }));
print(`-- db.wallets.find({ customer_id: 5 }): wallets are referenced, so they are a second query`);
db.wallets.find({ customer_id: 5 }, { wallet_number: 1, wallet_type: 1, balance: 1, status: 1 }).sort({ _id: 1 })
  .forEach(w => print(`   wallet ${w._id}  ${w.wallet_number}  ${w.wallet_type.padEnd(7)}  ${ngn(w.balance).padStart(15)}  ${w.status}`));

banner('3. Update: verify KYC, fund the wallet, save a beneficiary');

// Verify the BVN and raise the tier in one update of one document. A
// single-document write is atomic, so the tier can never be raised
// without the document being marked verified, or the other way round.
// In Portfolio 1 these are two rows in two tables.
r = db.customers.updateOne(
  { _id: customerId, kyc_documents: { $elemMatch: { document_id: documentId, status: 'submitted' } } },
  { $set: { 'kyc_documents.$.status': 'verified', 'kyc_documents.$.reviewed_at': lagos('10:15'),
            'kyc_documents.$.reviewed_by': 'compliance.adaeze', kyc_tier: 2 } });
check(`updateOne customers: BVN verified and kyc_tier 1 -> 2 in one write (matched ${r.matchedCount}, modified ${r.modifiedCount})`,
      r.modifiedCount === 1);
const auditId = () => nextId('audit_log');
db.audit_log.insertOne({ _id: auditId(), entity_type: 'kyc_document', entity_id: documentId, action: 'verified',
  actor_type: 'staff', actor_ref: 'compliance.adaeze', details: `bvn verified for customer ${customerId}`, created_at: lagos('10:15') });
const adaobi = db.customers.findOne({ _id: customerId });
print(`   now: kyc_tier ${adaobi.kyc_tier}, BVN ${adaobi.kyc_documents[0].status} by ${adaobi.kyc_documents[0].reviewed_by}; audit entry added`);

// Every money movement changes a wallet and adds a ledger entry: two
// documents in two collections, so it runs as a multi-document
// transaction. This is the MongoDB version of BEGIN ... COMMIT.
const session = db.getMongo().startSession();
const sdb = session.getDatabase(db.getName());
function begin() {
  session.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
}

begin();
sdb.wallets.updateOne({ _id: walletId, status: 'active' }, { $inc: { balance: NumberDecimal('80000.00') } });
sdb.transactions.insertOne({ _id: nextId('transactions'), reference: 'TXN2610310001', wallet_id: walletId,
  transaction_type: 'funding', amount: NumberDecimal('80000.00'), status: 'completed',
  narration: 'Bank transfer top-up', created_at: lagos('10:30') });
session.commitTransaction();
check(`fund wallet ${walletId} with NGN 80000.00 (wallet $inc + funding ledger entry, committed together): balance ${ngn(balanceOf(walletId))}`,
      balanceOf(walletId).toString() === '80000.00');

// Save Ngozi Eze's wallet as a beneficiary. The "not saved yet" check is
// in the filter, as in seed test 5.27, so it cannot be saved twice.
const beneficiaryId = nextEmbeddedId('beneficiaries', 'beneficiary_id');
const saveNgozi = () => db.customers.updateOne(
  { _id: customerId, 'beneficiaries.wallet_id': { $ne: 4 }, 'beneficiaries.nickname': { $ne: 'Ngozi' } },
  { $push: { beneficiaries: { beneficiary_id: beneficiaryId, wallet_id: 4, nickname: 'Ngozi', created_at: lagos('11:00') } } });
r = saveNgozi();
check(`save wallet 4 as beneficiary "Ngozi": modified ${r.modifiedCount}`, r.modifiedCount === 1);
r = saveNgozi();
check(`save it again: matched ${r.matchedCount}, modified ${r.modifiedCount} (already saved, nothing added)`, r.modifiedCount === 0);

banner('4. Money: transfers as multi-document transactions, and a merchant payment');

// A transfer touches four documents in three collections: debit the
// sender, credit the receiver, store the transfer, write two ledger
// legs. The debit only matches if the balance covers it (the atomic
// UPDATE ... WHERE balance >= x of Portfolio 3), and the credit only
// matches an active wallet. If either matches nothing, the transaction
// is aborted and every write in it is undone, then the failure is
// recorded on its own, as Portfolio 1 records failed transfers.
function transfer(t) {
  const amount = NumberDecimal(t.amount);
  const transferId = nextId('transfers');
  const before = [balanceOf(t.from), balanceOf(t.to)];
  print(`-- ${t.reference}: NGN ${t.amount} from wallet ${t.from} to wallet ${t.to} ("${t.narration}")`);
  begin();
  let failure = null;
  const debit = sdb.wallets.updateOne({ _id: t.from, status: 'active', balance: { $gte: amount } },
                                      { $inc: { balance: NumberDecimal('-' + t.amount) } });
  if (debit.modifiedCount === 0) {
    failure = `Insufficient funds: balance ${ngn(before[0])}, requested NGN ${t.amount}`;
  } else {
    print(`   debit inside the transaction: modified ${debit.modifiedCount}; inside it reads ${ngn(sdb.wallets.findOne({ _id: t.from }).balance)}, ` +
          `outside it still reads ${ngn(balanceOf(t.from))}`);
    const credit = sdb.wallets.updateOne({ _id: t.to, status: 'active' }, { $inc: { balance: amount } });
    if (credit.modifiedCount === 0) failure = `Receiver wallet ${t.to} is ${db.wallets.findOne({ _id: t.to }).status}`;
  }
  if (failure) {
    session.abortTransaction();
    print(`   abortTransaction: ${failure}`);
    db.transfers.insertOne({ _id: transferId, reference: t.reference, sender_wallet_id: t.from, receiver_wallet_id: t.to,
      amount, narration: t.narration, status: 'failed', failure_reason: failure, created_at: t.at, processed_at: t.at });
    db.audit_log.insertOne({ _id: auditId(), entity_type: 'transfer', entity_id: transferId, action: 'failed',
      actor_type: 'system', actor_ref: 'transfer-engine', details: failure, created_at: t.at });
    print(`   recorded transfer ${transferId} as failed, with an audit entry; no ledger entries`);
  } else {
    sdb.transfers.insertOne({ _id: transferId, reference: t.reference, sender_wallet_id: t.from, receiver_wallet_id: t.to,
      amount, narration: t.narration, status: 'completed', created_at: t.at, processed_at: t.at });
    const leg = { transfer: { transfer_id: transferId, reference: t.reference }, amount, status: 'completed',
                  narration: t.narration, created_at: t.at };
    sdb.transactions.insertMany([
      Object.assign({ _id: nextId('transactions'), reference: t.legs[0], wallet_id: t.from, transaction_type: 'transfer_out' }, leg),
      Object.assign({ _id: nextId('transactions') + 1, reference: t.legs[1], wallet_id: t.to, transaction_type: 'transfer_in' }, leg)]);
    session.commitTransaction();
    print(`   commitTransaction: transfer ${transferId} completed with 2 ledger legs`);
  }
  const after = [balanceOf(t.from), balanceOf(t.to)];
  print(`   wallet ${t.from}: ${ngn(before[0])} -> ${ngn(after[0])};  wallet ${t.to}: ${ngn(before[1])} -> ${ngn(after[1])}`);
  return { failed: !!failure, before, after };
}

const sameBalances = x => x.after.every((v, i) => v.toString() === x.before[i].toString());
let t = transfer({ reference: 'TRF2610310001', legs: ['TXN2610310002', 'TXN2610310003'], from: walletId, to: 4,
                   amount: '25000.00', narration: 'Aso-ebi contribution', at: lagos('12:00') });
check('transfer of NGN 25000.00 committed: sender down 25000.00, receiver up 25000.00',
      !t.failed && t.after[0].toString() === '55000.00' && t.after[1].toString() === '70000.00');

t = transfer({ reference: 'TRF2610310002', from: walletId, to: 4,
               amount: '100000.00', narration: 'School fees', at: lagos('12:20') });
check('transfer of NGN 100000.00 aborted for insufficient funds: both balances unchanged',
      t.failed && sameBalances(t));

// Wallet 18 was frozen by compliance in the Portfolio 1 data. The debit
// succeeds inside the transaction, then the credit matches nothing, so
// the abort has a real write to undo.
t = transfer({ reference: 'TRF2610310003', from: walletId, to: 18,
               amount: '5000.00', narration: 'Thank you', at: lagos('12:40') });
check('transfer to frozen wallet 18 aborted after the debit: the debit was undone, both balances unchanged',
      t.failed && sameBalances(t));

// Merchant payment: the ledger entry carries a snapshot of the merchant,
// so a statement prints the name without a $lookup.
const m = db.merchants.findOne({ _id: 1 });
print(`-- merchant payment: NGN 12450.00 from wallet ${walletId} to merchant ${m._id} ${m.business_name} (${m.category})`);
begin();
const debit = sdb.wallets.updateOne({ _id: walletId, status: 'active', balance: { $gte: NumberDecimal('12450.00') } },
                                    { $inc: { balance: NumberDecimal('-12450.00') } });
if (debit.modifiedCount === 1) {
  sdb.transactions.insertOne({ _id: nextId('transactions'), reference: 'TXN2610310004', wallet_id: walletId,
    transaction_type: 'merchant_payment', amount: NumberDecimal('12450.00'), status: 'completed',
    merchant: { merchant_id: m._id, business_name: m.business_name, category: m.category },
    narration: 'Groceries', created_at: lagos('13:30') });
  session.commitTransaction();
} else {
  session.abortTransaction();
}
check(`merchant payment committed: wallet ${walletId} balance ${ngn(balanceOf(walletId))}`, balanceOf(walletId).toString() === '42550.00');
session.endSession();

banner('5. Read: wallet statement for October 2026');

// The same operation as Portfolio 2's Q1: one wallet's ledger for a date
// range, oldest first. The transfer reference and merchant name are
// already in each entry.
const from = new Date('2026-10-01T00:00:00+01:00'), to = new Date('2026-11-01T00:00:00+01:00');
print(`-- db.transactions.find({ wallet_id: ${walletId}, created_at: { $gte: ${from.toISOString()}, $lt: ${to.toISOString()} } }).sort({ created_at: 1 })`);
let running = NumberDecimal('0.00');
const credits = ['funding', 'transfer_in', 'reversal'];
const lines = db.transactions.find({ wallet_id: walletId, created_at: { $gte: from, $lt: to } }).sort({ created_at: 1 }).toArray();
for (const e of lines) {
  // Decimal arithmetic in the shell, so the running balance is exact.
  running = NumberDecimal(Decimal128Add(running, e.amount, credits.includes(e.transaction_type)));
  const detail = e.merchant ? e.merchant.business_name : e.transfer ? e.transfer.reference : '';
  const signed = (credits.includes(e.transaction_type) ? '+' : '-') + e.amount.toString();
  print(`   ${e.created_at.toISOString().slice(0, 16)}Z  ${e.reference}  ${e.transaction_type.padEnd(16)}` +
        `${signed.padStart(10)}  ${running.toString().padStart(9)}  ${e.narration}${detail ? ' / ' + detail : ''}`);
}
check(`statement: ${lines.length} entries, closing balance ${ngn(running)} equals the wallet balance`,
      lines.length === 3 && running.toString() === balanceOf(walletId).toString());

// Exact decimal add or subtract, done in cents with BigInt.
function Decimal128Add(a, b, add) {
  const cents = d => { const [i, f = ''] = d.toString().split('.'); return BigInt(i) * 100n + (i.startsWith('-') ? -1n : 1n) * BigInt((f + '00').slice(0, 2)); };
  const c = cents(a) + (add ? 1n : -1n) * cents(b);
  const s = c < 0n ? '-' : '', v = c < 0n ? -c : c;
  return `${s}${v / 100n}.${String(v % 100n).padStart(2, '0')}`;
}

banner('6. Delete: remove a beneficiary; close a wallet');

// Beneficiaries are not financial records, so one can be deleted: a
// $pull removes the embedded element (Portfolio 1: DELETE FROM
// beneficiaries).
r = db.customers.updateOne({ _id: customerId }, { $pull: { beneficiaries: { wallet_id: 4 } } });
check(`$pull beneficiary wallet 4 from customer ${customerId}: modified ${r.modifiedCount}, ` +
      `${db.customers.findOne({ _id: customerId }).beneficiaries.length} beneficiaries left`, r.modifiedCount === 1);

// Financial records are never deleted (case study rule 11). Portfolio 1
// enforces this with ON DELETE RESTRICT; MongoDB has no such rule (seed
// test 5.25), so the application checks the ledger before any delete.
function deleteWallet(id) {
  const entries = db.transactions.countDocuments({ wallet_id: id });
  if (entries > 0) return `refused: ${entries} ledger entries point at wallet ${id}`;
  return `deleted ${db.wallets.deleteOne({ _id: id }).deletedCount}`;
}
const refusal = deleteWallet(walletId);
check(`application-side RESTRICT: delete wallet ${walletId} ${refusal}`, refusal.startsWith('refused'));

// So a wallet is closed through its status. Adaobi opened a savings
// wallet by mistake and asks for it to be closed. The filter only closes
// an empty wallet.
const savingsId = nextId('wallets');
db.wallets.insertOne({ _id: savingsId, customer_id: customerId, wallet_number: '6216039483', wallet_type: 'savings',
                       balance: NumberDecimal('0.00'), status: 'active', created_at: lagos('14:00') });
r = db.wallets.updateOne({ _id: savingsId, status: 'active', balance: NumberDecimal('0.00') }, { $set: { status: 'closed' } });
db.audit_log.insertOne({ _id: auditId(), entity_type: 'wallet', entity_id: savingsId, action: 'status_changed',
  actor_type: 'staff', actor_ref: 'support.kunle', details: 'Savings wallet closed at customer request; balance NGN 0.00', created_at: lagos('14:10') });
check(`savings wallet ${savingsId} opened, then closed through its status (modified ${r.modifiedCount}); it is still stored: ` +
      `status ${db.wallets.findOne({ _id: savingsId }).status}`, r.modifiedCount === 1);

banner('7. Counts and integrity audits after the operations');

const added = { customers: 1, wallets: 2, merchants: 0, transfers: 3, transactions: 4, audit_log: 4 };
for (const name of collections) {
  const n = db.getCollection(name).countDocuments();
  check(`${name.padEnd(13)} ${String(n).padStart(3)} documents (${expected[name]} seeded + ${added[name]})`, n === expected[name] + added[name]);
}
const b = balanceMismatches();
check(`balance audit: ${b.length} of ${db.wallets.countDocuments()} wallets differ from their ledger total`, b.length === 0);
b.forEach(d => printjson(d));
const l = legMismatches();
check(`transfer audit: ${l.length} of ${db.transactions.countDocuments({ transfer: { $exists: true } })} transfer ledger entries disagree with their transfer`, l.length === 0);
l.forEach(d => printjson(d));

print('');
print(failures === 0 ? 'All checks passed.' : `${failures} check(s) did not come out as expected.`);
if (failures > 0) quit(1);
