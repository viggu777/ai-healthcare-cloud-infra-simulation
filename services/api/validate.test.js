'use strict';

/* Unit tests for services/api/validate.js — run with `node --test` (no deps).
 * Pipeline stage: unit (see scripts/pipeline.sh, .github/workflows/pipeline.yml).
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { validateAppointment } = require('./validate');

describe('validateAppointment', () => {
  it('accepts a valid patient+doctor payload', () => {
    assert.equal(validateAppointment({ patient: 'p1', doctor: 'dr-a' }), null);
  });

  it('ignores extra fields', () => {
    assert.equal(validateAppointment({ patient: 'p1', doctor: 'dr-a', extra: 1 }), null);
  });

  it('rejects a missing patient', () => {
    assert.equal(
      validateAppointment({ doctor: 'dr-a' }),
      'patient and doctor are required strings',
    );
  });

  it('rejects a missing doctor', () => {
    assert.equal(
      validateAppointment({ patient: 'p1' }),
      'patient and doctor are required strings',
    );
  });

  it('rejects non-string types', () => {
    assert.equal(
      validateAppointment({ patient: 42, doctor: 'dr-a' }),
      'patient and doctor are required strings',
    );
    assert.equal(
      validateAppointment({ patient: 'p1', doctor: null }),
      'patient and doctor are required strings',
    );
  });

  it('rejects empty / null / undefined bodies', () => {
    assert.equal(validateAppointment({}), 'patient and doctor are required strings');
    assert.equal(validateAppointment(null), 'patient and doctor are required strings');
    assert.equal(validateAppointment(undefined), 'patient and doctor are required strings');
  });
});
