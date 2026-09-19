// MongoDB init for Phase 1 simulation. Runs once on first volume init.
// Creates app collections + indexes. Auth user itself comes from
// MONGO_INITDB_ROOT_USERNAME/PASSWORD (admin). App uses same creds via ?authSource=admin.
// Least-privilege (P0 hardening): two per-service users on `healthcare` —
// api_user (API: readWrite) and worker_user (worker: readWrite). Fresh volumes
// get them here with placeholder passwords (override via live rotation script
// before any shared use); EXISTING volumes predate this file and get them via
// scripts/create-db-users.sh (idempotent, uses root creds from env file).
db = db.getSiblingDB('healthcare');
db.createCollection('appointments');
db.createCollection('jobs');
db.appointments.createIndex({ status: 1, createdAt: -1 });
db.jobs.createIndex({ status: 1, updatedAt: -1 });
print('mongo-init: healthcare collections ready');
try {
  db.createUser({
    user: 'api_user', pwd: 'api_only_change_me',
    roles: [{ role: 'readWrite', db: 'healthcare' }],
  });
  print('mongo-init: api_user created (readWrite on healthcare)');
} catch (e) { print('mongo-init: api_user exists, skipping: ' + e.message); }
try {
  db.createUser({
    user: 'worker_user', pwd: 'worker_only_change_me',
    roles: [{ role: 'readWrite', db: 'healthcare' }],
  });
  print('mongo-init: worker_user created (readWrite on healthcare)');
} catch (e) { print('mongo-init: worker_user exists, skipping: ' + e.message); }
