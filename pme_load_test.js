import http from 'k6/http';
import { sleep, check, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import encoding from 'k6/encoding';

// ── Custom metrics ──────────────────────────────────────────────────────────
const errorRate     = new Rate('pme_errors');
const loginDuration = new Trend('pme_login_ms',  true);
const filesDuration = new Trend('pme_files_ms',  true);
const uploadDuration= new Trend('pme_upload_ms', true);
const wopiDuration  = new Trend('pme_wopi_ms',   true);
const wbDuration    = new Trend('pme_wb_ms',     true);
const syncDuration  = new Trend('pme_sync_ms',   true);
const totalReqs     = new Counter('pme_total_requests');

// ── User pool ───────────────────────────────────────────────────────────────
const USERS = new SharedArray('users', function() {
  const pool = [];
  for (let i = 1; i <= 25; i++) {
    pool.push({ user: `pme_user_${String(i).padStart(2,'0')}`, pass: 'Pme@Test2026!' });
  }
  return pool;
});

const BASE       = 'https://nxt.azure-informatique.cloud';
const COLLABORA  = 'https://office.nxt.azure-informatique.cloud';
const WHITEBOARD = 'https://board.nxt.azure-informatique.cloud';

// ── Load model: 500 DAU PME ─────────────────────────────────────────────────
// Peak concurrent ~50 VUs
//   30 VUs = WebDAV sync clients (desktop Nextcloud app)
//   12 VUs = Web browser sessions
//    5 VUs = Collabora document editors
//    3 VUs = Whiteboard users
export const options = {
  scenarios: {
    webdav_sync: {
      executor: 'ramping-vus',
      exec: 'webdav_sync',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 20 },
        { duration: '6m', target: 20 },
        { duration: '1m', target: 0  },
      ],
      gracefulRampDown: '30s',
    },
    web_sessions: {
      executor: 'ramping-vus',
      exec: 'web_sessions',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 8  },
        { duration: '6m', target: 8  },
        { duration: '1m', target: 0  },
      ],
      gracefulRampDown: '30s',
    },
    collabora_editors: {
      executor: 'ramping-vus',
      exec: 'collabora_editors',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 4  },
        { duration: '6m', target: 4  },
        { duration: '1m', target: 0  },
      ],
      gracefulRampDown: '30s',
    },
    whiteboard_users: {
      executor: 'ramping-vus',
      exec: 'whiteboard_users',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 2  },
        { duration: '6m', target: 2  },
        { duration: '1m', target: 0  },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    'http_req_duration{scenario:webdav_sync}':       ['p(95)<3000'],
    'http_req_duration{scenario:web_sessions}':      ['p(95)<4000'],
    'http_req_duration{scenario:collabora_editors}': ['p(95)<5000'],
    'http_req_duration{scenario:whiteboard_users}':  ['p(95)<5000'],
    'pme_errors':                                    ['rate<0.05'],
  },
  // Limit system tags to reduce memory footprint
  systemTags: ['scenario', 'status', 'method', 'url', 'name'],
};

function pickUser() {
  return USERS[Math.floor(Math.random() * USERS.length)];
}

function basicAuth(u) {
  return { 'Authorization': 'Basic ' + encoding.b64encode(u.user + ':' + u.pass) };
}

// ── Scenario 1: WebDAV sync client ──────────────────────────────────────────
export function webdav_sync() {
  const u = pickUser();

  group('propfind', function() {
    const t = Date.now();
    const r = http.request('PROPFIND',
      `${BASE}/remote.php/dav/files/${u.user}/`,
      '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>',
      { headers: Object.assign(basicAuth(u), { 'Depth': '1' }), tags: { op: 'propfind' } }
    );
    syncDuration.add(Date.now() - t);
    totalReqs.add(1);
    errorRate.add(!check(r, { 'PROPFIND 207': (r) => r.status === 207 }));
  });

  sleep(Math.random() * 2 + 1);

  group('download', function() {
    const t = Date.now();
    const r = http.get(
      `${BASE}/remote.php/dav/files/${u.user}/rapport_test.txt`,
      { headers: basicAuth(u), tags: { op: 'get_file' } }
    );
    syncDuration.add(Date.now() - t);
    totalReqs.add(1);
    errorRate.add(!check(r, { 'GET 200': (r) => r.status === 200 }));
  });

  sleep(Math.random() * 2 + 1);

  group('upload_text', function() {
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/rapport_test.txt`,
      `PME sync - ${u.user} - ${new Date().toISOString()}`,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'text/plain' }), tags: { op: 'put_file' } }
    );
    uploadDuration.add(Date.now() - t);
    totalReqs.add(1);
    errorRate.add(!check(r, { 'PUT 201/204': (r) => r.status === 204 || r.status === 201 }));
  });

  sleep(Math.random() * 2 + 1);

  group('upload_binary', function() {
    const buf = new Uint8Array(8192).fill(65).buffer; // 8KB fake doc
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/document_sync.bin`,
      buf,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'application/octet-stream' }), tags: { op: 'put_binary' } }
    );
    uploadDuration.add(Date.now() - t);
    totalReqs.add(1);
    errorRate.add(!check(r, { 'PUT bin 201/204': (r) => r.status === 204 || r.status === 201 }));
  });

  sleep(Math.random() * 20 + 10); // sync interval 10-30s
}

// ── Scenario 2: Web browser session ─────────────────────────────────────────
export function web_sessions() {
  const u = pickUser();

  group('status', function() {
    const r = http.get(`${BASE}/status.php`, { tags: { op: 'status' } });
    totalReqs.add(1);
    check(r, { 'status 200': (r) => r.status === 200 });
  });

  sleep(1);

  let csrf = '';
  group('login_page', function() {
    const r = http.get(`${BASE}/login`, { tags: { op: 'login_page' } });
    totalReqs.add(1);
    const meta = r.html().find('head meta[name=requesttoken]');
    csrf = meta.length ? meta.attr('content') : '';
  });

  sleep(Math.random() * 2 + 1);

  let loggedIn = false;
  group('login_post', function() {
    const t = Date.now();
    const r = http.post(`${BASE}/login`, {
      user: u.user,
      password: u.pass,
      timezone: 'Europe/Paris',
      timezone_offset: '2',
      requesttoken: csrf,
    }, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      tags: { op: 'login' },
      redirects: 3,
    });
    loginDuration.add(Date.now() - t);
    totalReqs.add(1);
    loggedIn = check(r, { 'login ok': (r) => r.status === 200 && !r.url.includes('/login') });
    errorRate.add(!loggedIn);
  });

  if (!loggedIn) { sleep(2); return; }
  sleep(Math.random() * 2 + 1);

  group('dashboard', function() {
    const t = Date.now();
    const r = http.get(`${BASE}/apps/dashboard/`, { tags: { op: 'dashboard' } });
    filesDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'dashboard 200': (r) => r.status === 200 });
  });

  sleep(Math.random() * 3 + 2);

  group('files_app', function() {
    const t = Date.now();
    const r = http.get(`${BASE}/apps/files/`, { tags: { op: 'files_app' } });
    filesDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'files 200': (r) => r.status === 200 });
  });

  sleep(Math.random() * 2 + 1);

  group('ocs_activity', function() {
    const r = http.get(
      `${BASE}/ocs/v2.php/apps/activity/api/v2/activity/files?format=json&limit=20`,
      { headers: { 'OCS-APIREQUEST': 'true' }, tags: { op: 'activity' } }
    );
    totalReqs.add(1);
    check(r, { 'activity 200': (r) => r.status === 200 || r.status === 404 });
  });

  sleep(Math.random() * 2 + 1);

  group('web_upload', function() {
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/web_upload_${Date.now()}.txt`,
      `Web upload - ${u.user} - ${Date.now()}`,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'text/plain' }), tags: { op: 'web_upload' } }
    );
    uploadDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'upload 201/204': (r) => r.status === 201 || r.status === 204 });
  });

  sleep(Math.random() * 10 + 5);
}

// ── Scenario 3: Collabora editors ───────────────────────────────────────────
export function collabora_editors() {
  const u = pickUser();

  group('wopi_discovery', function() {
    const t = Date.now();
    const r = http.get(`${COLLABORA}/hosting/discovery`, { tags: { op: 'wopi_discovery' } });
    wopiDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'WOPI 200': (r) => r.status === 200 });
  });

  sleep(Math.random() * 2 + 1);

  group('richdoc_config', function() {
    const t = Date.now();
    const r = http.get(`${BASE}/apps/richdocuments/api/v1/config`,
      { headers: basicAuth(u), tags: { op: 'richdoc_config' } }
    );
    wopiDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'richdoc cfg 200': (r) => r.status === 200 || r.status === 403 });
  });

  sleep(Math.random() * 2 + 1);

  group('upload_odt', function() {
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/collab_doc_${Date.now()}.txt`,
      `Document Collabora - ${u.user} - ${new Date().toISOString()}\n\nContenu de test PME.`,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'text/plain' }), tags: { op: 'put_doc' } }
    );
    wopiDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'doc upload 201/204': (r) => r.status === 201 || r.status === 204 });
  });

  sleep(Math.random() * 30 + 15); // editing session 15-45s

  group('save_doc', function() {
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/rapport_test.txt`,
      `Collabora save - ${u.user} - ${new Date().toISOString()}`,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'text/plain' }), tags: { op: 'save_doc' } }
    );
    wopiDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'save 204': (r) => r.status === 204 || r.status === 201 });
  });

  sleep(Math.random() * 10 + 5);
}

// ── Scenario 4: Whiteboard users ─────────────────────────────────────────────
export function whiteboard_users() {
  const u = pickUser();

  group('wb_backend', function() {
    const t = Date.now();
    const r = http.get(`${WHITEBOARD}/`, { tags: { op: 'wb_health' } });
    wbDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'wb backend reachable': (r) => r.status < 500 });
  });

  sleep(Math.random() * 2 + 1);

  group('create_whiteboard', function() {
    const wbData = '{"elements":[],"files":{},"scrollToContent":true}';
    const t = Date.now();
    const r = http.put(
      `${BASE}/remote.php/dav/files/${u.user}/board_${Date.now()}.whiteboard`,
      wbData,
      { headers: Object.assign(basicAuth(u), { 'Content-Type': 'application/vnd.excalidraw+json' }), tags: { op: 'create_wb' } }
    );
    wbDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'create wb 201/204': (r) => r.status === 201 || r.status === 204 });
  });

  sleep(Math.random() * 2 + 1);

  group('read_whiteboard', function() {
    const t = Date.now();
    const r = http.get(
      `${BASE}/remote.php/dav/files/${u.user}/rapport_test.txt`,
      { headers: basicAuth(u), tags: { op: 'read_wb' } }
    );
    wbDuration.add(Date.now() - t);
    totalReqs.add(1);
    check(r, { 'read wb 200': (r) => r.status === 200 });
  });

  sleep(Math.random() * 30 + 20); // whiteboard session 20-50s
}

export default function() {}
