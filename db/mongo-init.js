// MongoDB init for Phase 1 simulation. Runs once on first volume init.
// Creates app collections + indexes. Auth user itself comes from
// MONGO_INITDB_ROOT_USERNAME/PASSWORD (admin). App uses same creds via ?authSource=admin.
db = db.getSiblingDB('healthcare');
db.createCollection('appointments');
db.createCollection('jobs');
db.appointments.createIndex({ status: 1, createdAt: -1 });
db.jobs.createIndex({ status: 1, updatedAt: -1 });
print('mongo-init: healthcare collections ready');
