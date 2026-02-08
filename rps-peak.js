import http from 'k6/http';
import { check } from 'k6';

function toInt(value, fallback) {
  const n = Number.parseInt(String(value === null || value === undefined ? '' : value), 10);
  return Number.isFinite(n) ? n : fallback;
}

function toBool(value, fallback) {
  if (value === null || value === undefined) return fallback;
  const v = String(value).trim().toLowerCase();
  if (v === 'true' || v === '1' || v === 'yes' || v === 'y') return true;
  if (v === 'false' || v === '0' || v === 'no' || v === 'n') return false;
  return fallback;
}

const DEFAULT_URL = 'http://localhost:8890/license/assistance/Typofonderie-AiglonPro';

const TARGET_URL = String(__ENV.TARGET_URL || DEFAULT_URL);
const EXPECT_STATUS = toInt(__ENV.EXPECT_STATUS, 200);

const TARGET_RPS = toInt(__ENV.TARGET_RPS, toInt(__ENV.PEAK_RPS, 200));
const DURATION = String(__ENV.DURATION || '15m');
const PREALLOCATED_VUS = toInt(__ENV.PRE_ALLOCATED_VUS, 80);
const MAX_VUS = toInt(__ENV.MAX_VUS, 400);

const AUTH_BEARER = String(__ENV.AUTH_BEARER || '').trim();
const DISCARD_BODIES = toBool(__ENV.DISCARD_BODIES, true);

export const options = {
  scenarios: {
    rps_peak: {
      executor: 'constant-arrival-rate',
      rate: TARGET_RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PREALLOCATED_VUS,
      maxVUs: MAX_VUS,
      tags: {
        test_type: 'api',
        service: 'fontsninja-commerce-v3-api',
        mode: 'rps-peak',
        rps_target: String(TARGET_RPS),
      },
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.01' }],
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    checks: ['rate>0.99'],
  },
  discardResponseBodies: DISCARD_BODIES,
};

export default function () {
  const headers = {};
  if (AUTH_BEARER) {
    headers.Authorization = 'Bearer ' + AUTH_BEARER;
  }

  const res = http.get(TARGET_URL, {
    headers: headers,
    tags: {
      name: 'GET ' + TARGET_URL,
    },
  });

  check(res, {
    'status should match EXPECT_STATUS': function (r) {
      return r.status === EXPECT_STATUS;
    },
  });
}
