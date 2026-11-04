// =====================================================================
// Portfolio 5: Distributed and cloud database
// 07_atlas_replica_set.js  Cloud evidence from the MongoDB Atlas cluster
//                          used in Portfolio 4: its three-member replica
//                          set, a write with w: "majority", and a read
//                          with a secondary read preference.
//
// Run from the repo root (see SETUP.md for loading MONGODB_URI, and make
// sure your current IP is on the Atlas Network Access list):
//   mongosh "$MONGODB_URI" --quiet --file portfolio-5-distributed-cloud/tests/07_atlas_replica_set.js
//
// It works on the Portfolio 4 data as it stands (the 153 sample documents
// or the larger data from 03_indexes.js) and adds one funding for
// Chinedu Okafor (wallet 1), the same operation as the local test 02.
// Re-runnable: it first removes the funding and the audit entries a
// previous run added, so every run starts from the same balance. Times
// written are fixed (4 November 2026, Lagos time).
//
// Sections:
//   1. The replica set: members, roles, where it runs, replication lag
//   2. Each member on its own; a write sent straight to a secondary
//   3. Writes: a funding with w: "majority"; audit entries with w: 3 and w: 4
//   4. Reads: the balance from the primary, the statement from a secondary
//
// Exits with code 1 if any check does not come out as expected.
// =====================================================================

const proclus = db.getSiblingDB('proclus');
const REFERENCE = 'TXN2611040101';
const AMOUNT = NumberDecimal('50000.00');
const ACTOR = 'p5.replication_check';
const AT = new Date('2026-11-04T11:00:00+01:00');
const NOVEMBER = new Date('2026-11-01T00:00:00+01:00');

let failures = 0;
function banner(title) { print(`\n=== ${title} ===`); }
function check(label, ok) {
  print(`${ok ? 'ok  ' : 'FAIL'} ${label}`);
  if (!ok) failures++;
}
const host = h => h.replace(/\.mongodb\.net(:27017)?$/, '');
const ngn = d => 'NGN ' + d.toString();

// ---------------------------------------------------------------------
banner('1. The replica set');
// ---------------------------------------------------------------------

const hello = db.hello();
print(`replica set ${hello.setName}, MongoDB ${db.version()}`);
print(`members (hello.hosts): ${hello.hosts.length}`);
hello.hosts.forEach(h => print(`  ${host(h)}`));
print(`this connection's primary: ${host(hello.primary)}`);
print(`primary's tags: provider ${hello.tags.provider}, region ${hello.tags.region}, ` +
      `availability zone ${hello.tags.availabilityZone}, node type ${hello.tags.nodeType}`);

// rs.status(): each member's state, health and the time of the last
// operation it has applied (optimeDate). A secondary's lag is how far its
// optimeDate trails the primary's (one-second resolution).
const status = rs.status();
const primary = status.members.find(m => m.stateStr === 'PRIMARY');
print('\nrs.status():');
print('  member                          state      health  last applied (UTC)        lag   syncing from');
status.members.forEach(m => {
  const lag = (primary.optimeDate - m.optimeDate) / 1000;
  print(`  ${host(m.name).padEnd(31)} ${m.stateStr.padEnd(10)} ${String(m.health).padEnd(7)} ` +
        `${m.optimeDate.toISOString().padEnd(25)} ${(lag + ' s').padEnd(5)} ${m.syncSourceHost ? host(m.syncSourceHost) : '-'}`);
});
const states = status.members.map(m => m.stateStr).sort();
check('three members: one PRIMARY and two SECONDARY',
      states.length === 3 && states.join(',') === 'PRIMARY,SECONDARY,SECONDARY');
check('every member healthy', status.members.every(m => m.health === 1));

// ---------------------------------------------------------------------
banner('2. Each member on its own');
// ---------------------------------------------------------------------

// A direct connection to one member, bypassing replica-set discovery. The
// user and password come from the same connection string.
const credentials = process.env.MONGODB_URI.match(/^mongodb\+srv:\/\/([^@]+)@/)[1];
function direct(member) {
  return new Mongo(`mongodb://${credentials}@${member}/?tls=true&authSource=admin&directConnection=true`);
}

let aSecondary = null;
hello.hosts.forEach(h => {
  const r = direct(h).getDB('admin').runCommand({ hello: 1 });
  print(`  ${host(r.me).padEnd(31)} isWritablePrimary ${String(r.isWritablePrimary).padEnd(5)} ` +
        `secondary ${String(r.secondary).padEnd(5)} last write ${r.lastWrite.lastWriteDate.toISOString()}`);
  if (r.secondary && !aSecondary) aSecondary = h;
});

// Only the primary accepts writes. Sent straight to a secondary, the same
// insert is refused, as the local replica refused writes in test 03.
print(`\nAn audit entry written straight to ${host(aSecondary)}:`);
try {
  direct(aSecondary).getDB('proclus').audit_log.insertOne({
    _id: 999999, entity_type: 'wallet', entity_id: 1, action: 'audited', actor_type: 'system',
    actor_ref: ACTOR, details: 'written to a secondary', created_at: AT });
  check('the secondary refused the write', false);
} catch (e) {
  print(`  refused: ${e.codeName} (${e.code}): ${e.message}`);
  check('the secondary refused the write', e.codeName === 'NotWritablePrimary');
}

// ---------------------------------------------------------------------
banner('3. Writes and write concern');
// ---------------------------------------------------------------------

// Undo a previous run: its funding (ledger entry and balance) and its
// audit entries, in one transaction.
const session = db.getMongo().startSession({ causalConsistency: true });
const s = session.getDatabase('proclus');
const previous = proclus.transactions.findOne({ reference: REFERENCE });
if (previous) {
  session.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
  s.wallets.updateOne({ _id: previous.wallet_id }, { $inc: { balance: NumberDecimal('-' + previous.amount.toString()) } });
  s.transactions.deleteOne({ _id: previous._id });
  s.audit_log.deleteMany({ actor_ref: ACTOR });
  session.commitTransaction();
  print(`removed the funding ${REFERENCE} and audit entries left by a previous run`);
}

const before = proclus.wallets.findOne({ _id: 1 }).balance;
print(`Chinedu Okafor, wallet 1: ${ngn(before)}`);

// 3.1 The funding: the ledger entry and the balance change in one
// multi-document transaction, committed with w: "majority". The commit is
// acknowledged only once two of the three members have it, so it survives
// the loss of the primary: whichever secondary is elected next has it.
const nextTxnId = proclus.transactions.find().sort({ _id: -1 }).limit(1).toArray()[0]._id + 1;
session.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
s.transactions.insertOne({ _id: nextTxnId, reference: REFERENCE, wallet_id: 1, transaction_type: 'funding',
                           amount: AMOUNT, status: 'completed', narration: 'Bank transfer top-up', created_at: AT });
s.wallets.updateOne({ _id: 1 }, { $inc: { balance: AMOUNT } });
session.commitTransaction();
print(`\n3.1 funding ${REFERENCE} (ledger entry ${nextTxnId}) committed with writeConcern { w: "majority" }`);
check('funding committed and acknowledged by a majority', proclus.transactions.countDocuments({ reference: REFERENCE }) === 1);

// 3.2 w: 3 waits for all three members.
const nextAuditId = () => proclus.audit_log.find().sort({ _id: -1 }).limit(1).toArray()[0]._id + 1;
const auditEntry = (id, details) => ({ _id: id, entity_type: 'wallet', entity_id: 1, action: 'audited',
                                       actor_type: 'system', actor_ref: ACTOR, details, created_at: AT });
const auditW3 = nextAuditId();
const r3 = proclus.runCommand({ insert: 'audit_log', documents: [auditEntry(auditW3, 'balance checked after funding; written with w: 3')],
                                writeConcern: { w: 3, wtimeout: 10000 } });
print(`\n3.2 audit entry ${auditW3} with writeConcern { w: 3 }: n ${r3.n}, ok ${r3.ok}, ` +
      `writeConcernError ${r3.writeConcernError ? r3.writeConcernError.codeName : 'none'}`);
check('w: 3 acknowledged by all three members', r3.ok === 1 && r3.n === 1 && !r3.writeConcernError);

// 3.3 w: 4 asks for more members than exist. The server refuses the
// write concern, but only after applying the write on the primary: the
// error says the acknowledgement could not be given, not that the insert
// was undone. An application that retried blindly would write it twice.
const auditW4 = nextAuditId();
let r4;
try {
  r4 = proclus.runCommand({ insert: 'audit_log', documents: [auditEntry(auditW4, 'balance checked after funding; written with w: 4')],
                            writeConcern: { w: 4, wtimeout: 10000 } });
} catch (e) { r4 = { ok: 0, code: e.code, codeName: e.codeName, errmsg: e.message }; }
const w4Error = r4.writeConcernError || r4;
print(`\n3.3 audit entry ${auditW4} with writeConcern { w: 4 }: ${w4Error.codeName} (${w4Error.code}): ${w4Error.errmsg}`);
const storedW4 = proclus.audit_log.countDocuments({ _id: auditW4 });
print(`    audit entries with _id ${auditW4} stored anyway: ${storedW4}`);
check('w: 4 refused: only three data-bearing members', w4Error.codeName === 'UnsatisfiableWriteConcern');
check('the w: 4 insert was still applied', storedW4 === 1);

// ---------------------------------------------------------------------
banner('4. Reads and read preference');
// ---------------------------------------------------------------------

// 4.1 The balance, read from the primary, as Proclus's rule requires.
const balance = proclus.wallets.find({ _id: 1 }, { balance: 1 }).readPref('primary').toArray()[0].balance;
const balanceHost = proclus.wallets.find({ _id: 1 }).readPref('primary').explain().serverInfo.host;
print(`4.1 balance of wallet 1 read from ${balanceHost.replace(/\.mongodb\.net$/, '')} (readPref primary): ${ngn(balance)}`);
check('balance read from the primary', balanceHost + ':27017' === primary.name);
check(`balance is ${ngn(before)} + ${ngn(AMOUNT)}`, balance.toString() === (Number(before.toString()) + 50000).toFixed(2));

// 4.2 The November statement, read from a secondary. readConcern
// "majority" returns only data a majority has, and the causally consistent
// session makes the secondary wait until it has applied this session's
// own funding before answering, so the read cannot miss it.
const statement = s.transactions.find({ wallet_id: 1, created_at: { $gte: NOVEMBER } },
                                      { _id: 1, reference: 1, transaction_type: 1, amount: 1, created_at: 1 })
                                .sort({ created_at: 1, _id: 1 })
                                .readPref('secondary').readConcern('majority');
const statementHost = s.transactions.find({ wallet_id: 1, created_at: { $gte: NOVEMBER } })
                       .readPref('secondary').readConcern('majority').explain().serverInfo.host;
const rows = statement.toArray();
print(`\n4.2 November statement for wallet 1 read from ${statementHost.replace(/\.mongodb\.net$/, '')} (readPref secondary, readConcern majority, causal session):`);
rows.forEach(r => print(`    ${r._id}  ${r.reference}  ${r.transaction_type.padEnd(16)} ${ngn(r.amount).padStart(15)}  ${r.created_at.toISOString()}`));
const secondaryNames = status.members.filter(m => m.stateStr === 'SECONDARY').map(m => m.name);
check('statement read from a secondary', secondaryNames.includes(statementHost + ':27017'));
check('the secondary returned the funding', rows.some(r => r.reference === REFERENCE));

session.endSession();

banner('Result');
print(failures === 0 ? 'All checks passed.' : `${failures} check(s) failed.`);
if (failures > 0) quit(1);
