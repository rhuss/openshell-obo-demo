#!/usr/bin/env node
// Unit tests for demo/issuer/token-issuer.js (T023, T024, T025).
// Runs with no dependencies and no infrastructure.
// Starts the issuer as a child process with a dummy JWKS URI.

const { spawn } = require("child_process");
const http = require("http");
const crypto = require("crypto");
const path = require("path");

const os = require("os");

const ACCESS_TOKEN_SECRET = crypto.randomBytes(32).toString("hex");
const ISSUER_PORT = 19400 + Math.floor(Math.random() * 100);
const DEBUG_SOCKET_PATH = path.join(os.tmpdir(), `debug-test-${ISSUER_PORT}.sock`);
const ACCESS_TOKEN_ISSUER = `http://127.0.0.1:${ISSUER_PORT}`;

let issuerProc = null;
let passCount = 0;
let failCount = 0;
const failures = [];

function cleanup() {
  if (issuerProc) {
    issuerProc.kill("SIGTERM");
    issuerProc = null;
  }
  try { require("fs").unlinkSync(DEBUG_SOCKET_PATH); } catch (_) { /* ignore */ }
}

process.on("exit", cleanup);
process.on("SIGINT", () => { cleanup(); process.exit(1); });
process.on("SIGTERM", () => { cleanup(); process.exit(1); });

function pass(name) {
  passCount++;
  console.log(`  PASS  ${name}`);
}

function fail(name, reason) {
  failCount++;
  failures.push(name);
  console.log(`  FAIL  ${name}: ${reason}`);
}

function b64urlDecode(value) {
  const padded = `${value}${"=".repeat((4 - (value.length % 4)) % 4)}`;
  return Buffer.from(padded.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function parseJwt(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("not a JWT");
  return JSON.parse(b64urlDecode(parts[1]).toString("utf8"));
}

function httpGet(port, urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.get(`http://127.0.0.1:${port}${urlPath}`, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        try {
          resolve({ status: res.statusCode, body: JSON.parse(body) });
        } catch {
          resolve({ status: res.statusCode, body });
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(5000, () => req.destroy(new Error("timeout")));
  });
}

function httpGetSocket(socketPath, urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.get({ socketPath, path: urlPath }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        try {
          resolve({ status: res.statusCode, body: JSON.parse(body) });
        } catch {
          resolve({ status: res.statusCode, body });
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(5000, () => req.destroy(new Error("timeout")));
  });
}

function httpPost(port, urlPath, formBody) {
  return new Promise((resolve, reject) => {
    const data = new URLSearchParams(formBody).toString();
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port,
        path: urlPath,
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "content-length": Buffer.byteLength(data),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          try {
            resolve({ status: res.statusCode, body: JSON.parse(body) });
          } catch {
            resolve({ status: res.statusCode, body });
          }
        });
      },
    );
    req.on("error", reject);
    req.setTimeout(5000, () => req.destroy(new Error("timeout")));
    req.write(data);
    req.end();
  });
}

function startIssuer() {
  return new Promise((resolve, reject) => {
    const issuerPath = path.resolve(__dirname, "..", "issuer", "token-issuer.js");
    issuerProc = spawn("node", [issuerPath], {
      env: {
        ...process.env,
        PORT: String(ISSUER_PORT),
        DEBUG_SOCKET_PATH,
        ACCESS_TOKEN_SECRET,
        ACCESS_TOKEN_ISSUER,
        SPIRE_JWKS_URI: "http://127.0.0.1:1/nonexistent",
        SPIRE_ISSUER: "http://127.0.0.1:1/nonexistent",
        JWT_SVID_AUDIENCE: ACCESS_TOKEN_ISSUER,
        DEMO_USER_SUBJECT: "demo-user",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let started = 0;
    const onData = (chunk) => {
      const text = chunk.toString();
      if (text.includes("listening on") || text.includes("listener on")) started++;
      // Wait for both servers (main + debug) to start
      if (started >= 2) {
        issuerProc.stdout.removeListener("data", onData);
        issuerProc.stderr.removeListener("data", onData);
        resolve();
      }
    };

    issuerProc.stdout.on("data", onData);
    issuerProc.stderr.on("data", onData);
    issuerProc.on("error", reject);
    issuerProc.on("exit", (code) => {
      if (started < 2) reject(new Error(`issuer exited with code ${code}`));
    });

    setTimeout(() => {
      if (started < 2) reject(new Error("issuer did not start within 5s"));
    }, 5000);
  });
}

async function runTests() {
  console.log("\nIssuer claims tests\n");

  // ── T024: Subject token lifetime ────────────────────────────────────
  {
    const res = await httpGet(ISSUER_PORT, "/demo-subject-token");
    if (res.status !== 200) {
      fail("subject-token-endpoint", `status ${res.status}`);
    } else {
      pass("subject-token-endpoint-200");

      // Check expires_in in response
      if (res.body.expires_in >= 5400) {
        pass("subject-token-expires-in-response >= 5400");
      } else {
        fail("subject-token-expires-in-response", `got ${res.body.expires_in}, want >= 5400`);
      }

      // Decode and check payload
      const claims = parseJwt(res.body.access_token);
      if (claims.exp - claims.iat >= 5400) {
        pass("subject-token-exp-minus-iat >= 5400");
      } else {
        fail("subject-token-exp-minus-iat", `got ${claims.exp - claims.iat}, want >= 5400`);
      }

      if (claims.sub === "demo-user") {
        pass("subject-token-sub is demo-user");
      } else {
        fail("subject-token-sub", `got ${claims.sub}`);
      }

      if (claims.demo_token_use === "user_subject") {
        pass("subject-token-demo_token_use is user_subject");
      } else {
        fail("subject-token-demo_token_use", `got ${claims.demo_token_use}`);
      }
    }
  }

  // ── T023: Act chain (via subject token structure) ───────────────────
  // We cannot do a full exchange without SPIRE, but we can verify the
  // subject token does NOT have an act claim (it shouldn't), and we can
  // verify the debug endpoint starts empty.
  {
    const res = await httpGet(ISSUER_PORT, "/demo-subject-token");
    const claims = parseJwt(res.body.access_token);
    if (!claims.act) {
      pass("subject-token-has-no-act (correct: only exchange tokens get act)");
    } else {
      fail("subject-token-act", "subject token should not have act claim");
    }
  }

  // ── T031: Debug endpoint (UNIX socket, C3) ─────────────────────────
  {
    const res = await httpGetSocket(DEBUG_SOCKET_PATH, "/debug/last-token");
    if (res.status === 200 && Array.isArray(res.body.tokens) && res.body.tokens.length === 0) {
      pass("debug-endpoint-empty-initially");
    } else {
      fail("debug-endpoint", `unexpected response: ${JSON.stringify(res.body)}`);
    }
  }

  // ── T025: Rejection contracts ───────────────────────────────────────

  // Bad grant_type
  {
    const res = await httpPost(ISSUER_PORT, "/token", { grant_type: "bad" });
    if (res.status === 400 && res.body.error === "unsupported_grant_type") {
      pass("reject-bad-grant_type");
    } else {
      fail("reject-bad-grant_type", `${res.status} ${JSON.stringify(res.body)}`);
    }
  }

  // Bad client_assertion_type
  {
    const gt = "urn:ietf:params:oauth:grant-type:token-exchange";
    const res = await httpPost(ISSUER_PORT, "/token", {
      grant_type: gt,
      client_assertion_type: "bad",
    });
    if (res.status === 400 && res.body.error === "unsupported_client_assertion_type") {
      pass("reject-bad-client_assertion_type");
    } else {
      fail("reject-bad-client_assertion_type", `${res.status} ${JSON.stringify(res.body)}`);
    }
  }

  // Missing client_assertion
  {
    const gt = "urn:ietf:params:oauth:grant-type:token-exchange";
    const cat = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe";
    const res = await httpPost(ISSUER_PORT, "/token", {
      grant_type: gt,
      client_assertion_type: cat,
    });
    if (res.status === 400 && res.body.error === "missing_client_assertion") {
      pass("reject-missing-client_assertion");
    } else {
      fail("reject-missing-client_assertion", `${res.status} ${JSON.stringify(res.body)}`);
    }
  }

  // Missing subject_token
  {
    const gt = "urn:ietf:params:oauth:grant-type:token-exchange";
    const cat = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe";
    const res = await httpPost(ISSUER_PORT, "/token", {
      grant_type: gt,
      client_assertion_type: cat,
      client_assertion: "fake.jwt.value",
    });
    if (res.status === 400 && res.body.error === "missing_subject_token") {
      pass("reject-missing-subject_token");
    } else {
      fail("reject-missing-subject_token", `${res.status} ${JSON.stringify(res.body)}`);
    }
  }

  // Invalid client_assertion (JWKS unreachable, so it errors on verification)
  {
    const gt = "urn:ietf:params:oauth:grant-type:token-exchange";
    const cat = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe";
    // Provide a well-formed but invalid subject_token so the code reaches
    // the SVID verification path which will fail (JWKS unreachable)
    const res = await httpPost(ISSUER_PORT, "/token", {
      grant_type: gt,
      client_assertion_type: cat,
      client_assertion: "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QifQ.eyJzdWIiOiJ0ZXN0In0.dGVzdA",
      subject_token: "not-a-valid-token",
    });
    // With an invalid subject_token, verifyAccessToken fails for both
    // user_subject and intermediate, so it falls through to verifyJwtSvid
    // which fails because JWKS is unreachable. This should yield 500 or
    // 401 (invalid_client). Either way, it must NOT return 200.
    if (res.status !== 200) {
      pass("reject-invalid-client_assertion (non-200)");
    } else {
      fail("reject-invalid-client_assertion", "expected non-200");
    }
  }

  // Subject token with wrong demo_token_use (use a valid HMAC-signed token
  // but with demo_token_use="final" instead of "user_subject" or "intermediate")
  {
    const gt = "urn:ietf:params:oauth:grant-type:token-exchange";
    const cat = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe";
    // Craft a valid-signature token with wrong demo_token_use
    const now = Math.floor(Date.now() / 1000);
    const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" }))
      .toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const payload = Buffer.from(JSON.stringify({
      iss: ACCESS_TOKEN_ISSUER,
      sub: "demo-user",
      demo_token_use: "final",
      iat: now,
      exp: now + 300,
    })).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const sigInput = `${header}.${payload}`;
    const sig = crypto.createHmac("sha256", ACCESS_TOKEN_SECRET)
      .update(sigInput).digest();
    const sigB64 = sig.toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const fakeToken = `${sigInput}.${sigB64}`;

    const res = await httpPost(ISSUER_PORT, "/token", {
      grant_type: gt,
      client_assertion_type: cat,
      client_assertion: "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QifQ.eyJzdWIiOiJ0ZXN0In0.dGVzdA",
      subject_token: fakeToken,
    });
    // The token has valid signature but wrong demo_token_use ("final"),
    // so verifyAccessToken("user_subject") fails, then verifyAccessToken("intermediate")
    // also fails, both with invalid_subject_token. The code should return that error.
    if (res.body.error === "invalid_subject_token") {
      pass("reject-wrong-demo_token_use returns invalid_subject_token");
    } else {
      // It may also fail at JWKS fetch (server_error) because the client_assertion
      // is still invalid. But invalid_subject_token should come first since
      // the subject token check happens before SVID verification in phase two.
      // Actually: the code tries user_subject first (fails), then falls through
      // to phase two where it explicitly calls verifyAccessToken("intermediate")
      // which throws invalid_subject_token.
      fail("reject-wrong-demo_token_use", `got ${res.status} ${JSON.stringify(res.body)}`);
    }
  }

  // ── Healthz ─────────────────────────────────────────────────────────
  {
    const res = await httpGet(ISSUER_PORT, "/healthz");
    if (res.status === 200) {
      pass("healthz-200");
    } else {
      fail("healthz", `status ${res.status}`);
    }
  }

  // ── 404 for unknown paths ───────────────────────────────────────────
  {
    const res = await httpGet(ISSUER_PORT, "/nonexistent");
    if (res.status === 404 && res.body.error === "not_found") {
      pass("unknown-path-404");
    } else {
      fail("unknown-path-404", `${res.status} ${JSON.stringify(res.body)}`);
    }
  }
}

async function main() {
  try {
    await startIssuer();
  } catch (err) {
    console.error(`Failed to start issuer: ${err.message}`);
    process.exit(1);
  }

  try {
    await runTests();
  } finally {
    cleanup();
  }

  console.log("");
  if (failCount > 0) {
    console.log(`${failCount} failed, ${passCount} passed`);
    failures.forEach((f) => console.log(`  FAILED: ${f}`));
    process.exit(1);
  }
  console.log(`All ${passCount} tests passed`);
  process.exit(0);
}

main();
