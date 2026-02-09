import http from 'k6/http';
import {check, sleep} from 'k6';
import {toInt} from './lib.js';

export const EXPECT_STATUS = toInt(__ENV.EXPECT_STATUS, 200);

const TARGET_VUS = toInt(__ENV.TARGET_VUS, 50);
const RAMP_UP = __ENV.RAMP_UP || '30s';
const STEADY = __ENV.STEADY || '1m';
const RAMP_DOWN = __ENV.RAMP_DOWN || '30s';

const AUTH_BEARER = String(__ENV.AUTH_BEARER || '').trim();

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      stages: [
        {duration: RAMP_UP, target: TARGET_VUS},
        {duration: STEADY, target: TARGET_VUS},
        {duration: RAMP_DOWN, target: 0},
      ],
      tags: {test_type: 'api', service: 'fontsninja-commerce-v3-api'},
    },
  },
  thresholds: {
    http_req_failed: [{threshold: 'rate<0.01'}],
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    checks: ['rate>0.99'],
  },
  discardResponseBodies: true,
};

export function runTest (url) {
  const headers = {};
  if (AUTH_BEARER) {
    headers.Authorization = `Bearer ${AUTH_BEARER}`;
  }

  const params = {
    headers,
    tags: {
      name: `GET ${url}`,
    },
  };

  const res = http.get(url, params);

  check(
      res,
      {
        'status should match EXPECT_STATUS': (r) => r.status === EXPECT_STATUS,
      },
      {url: url},
  );

  // Keep a small sleep to avoid a pure "hot loop" when iterating locally.
  sleep(1);
}
