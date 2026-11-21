// k6 load scenario for the deployed gateway.
//
// `scripts/loadtest.py` is the instrumented version: it separates handshake cost from
// request cost and can rotate a client certificate mid-run. This one is the blunt
// instrument for "does the deployed stack hold up", and it exists because k6 is a single
// static binary that runs anywhere, including a CI runner, with thresholds that fail the
// build instead of printing numbers nobody reads.
//
//   k6 run scripts/loadtest.k6.js
//   BASE_URL=https://showcase-dev.azurecontainerapps.io k6 run scripts/loadtest.k6.js
//
// Two scenarios run together: `login` is CPU-heavy on purpose (scrypt is memory-hard), so
// it drives the autoscaler; `catalog` is I/O-bound and shows where replicas help less.
// The thresholds encode the promise the README makes about p95, not a benchmark record.

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
const PASSWORD = __ENV.LOADTEST_PASSWORD || 'correct-horse-battery';
const EMAIL = __ENV.LOADTEST_EMAIL || `k6-${Date.now()}@example.com`;

const errors = new Rate('errors');
const loginDuration = new Trend('login_duration', true);
const catalogDuration = new Trend('catalog_duration', true);

export const options = {
  scenarios: {
    login: {
      executor: 'ramping-vus',
      exec: 'login',
      startVUs: 0,
      stages: [
        { duration: '20s', target: 10 },
        { duration: '40s', target: 30 },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
    catalog: {
      executor: 'constant-vus',
      exec: 'catalog',
      vus: 10,
      duration: '70s',
    },
  },
  thresholds: {
    // A 5% error budget is generous for a demo and still catches a broken deploy: a failed
    // login or a 5xx from the gateway trips it immediately.
    errors: ['rate<0.05'],
    'http_req_failed{scenario:login}': ['rate<0.05'],
    'http_req_failed{scenario:catalog}': ['rate<0.05'],
    'http_req_duration{scenario:login}': ['p(95)<1500'],
    'http_req_duration{scenario:catalog}': ['p(95)<500'],
  },
};

// One account for the whole run: registering per VU would measure the registration path
// (and its unique index) instead of the login path, which is the one that scales.
export function setup() {
  http.post(
    `${BASE_URL}/auth/register`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } },
  );

  const login = http.post(
    `${BASE_URL}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } },
  );

  check(login, {
    'setup login returned 200': (r) => r.status === 200,
    'setup login returned a token': (r) => Boolean(r.json('access_token')),
  });

  return { token: login.json('access_token') };
}

export function login() {
  const response = http.post(
    `${BASE_URL}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'POST /auth/login' } },
  );

  loginDuration.add(response.timings.duration);
  errors.add(response.status !== 200);

  check(response, {
    'login 200': (r) => r.status === 200,
    'login returns an access token': (r) => Boolean(r.json('access_token')),
  });
}

export function catalog(data) {
  const response = http.get(`${BASE_URL}/catalog/items`, {
    headers: { Authorization: `Bearer ${data.token}` },
    tags: { name: 'GET /catalog/items' },
  });

  catalogDuration.add(response.timings.duration);
  errors.add(response.status !== 200);

  check(response, {
    'catalog 200': (r) => r.status === 200,
    'catalog returns a list': (r) => Array.isArray(r.json()),
  });
}

export function handleSummary(data) {
  return {
    'k6-summary.json': JSON.stringify(data, null, 2),
    stdout: `\np95 login ${data.metrics.login_duration?.values['p(95)']?.toFixed(1) ?? 'n/a'} ms` +
      ` | p95 catalog ${data.metrics.catalog_duration?.values['p(95)']?.toFixed(1) ?? 'n/a'} ms` +
      ` | error rate ${((data.metrics.errors?.values.rate ?? 0) * 100).toFixed(2)}%\n`,
  };
}
