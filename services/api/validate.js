'use strict';

/* Appointment payload validation — extracted as a pure module so the pipeline's
 * unit stage can test it with zero dependencies (node:test + assert only).
 * Contract mirrors the original inline check byte-for-byte: same 422 status and
 * same `detail` string in server.js. No behavior change.
 */

function validateAppointment(body) {
  const { patient, doctor } = body || {};
  if (typeof patient !== 'string' || typeof doctor !== 'string') {
    return 'patient and doctor are required strings';
  }
  return null;
}

module.exports = { validateAppointment };
