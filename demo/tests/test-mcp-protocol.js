// Unit tests for the MCP server (T037, T038).
// Runs with: node demo/tests/test-mcp-protocol.js
// No dependencies, no infrastructure. Starts the server as a child process.

const { spawn } = require("child_process");
const http = require("http");
const path = require("path");

const SERVER_PATH = path.resolve(__dirname, "../mcp/mcp-server.js");
const PORT = 18930 + Math.floor(Math.random() * 1000);

let serverProc;
let pass = 0;
let fail = 0;

function cleanup() {
  if (serverProc) {
    serverProc.kill("SIGTERM");
    serverProc = null;
  }
}
process.on("exit", cleanup);
process.on("SIGINT", () => { cleanup(); process.exit(1); });
process.on("SIGTERM", () => { cleanup(); process.exit(1); });

function startServer() {
  return new Promise((resolve, reject) => {
    serverProc = spawn(process.execPath, [SERVER_PATH], {
      env: { ...process.env, PORT: String(PORT) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let started = false;
    serverProc.stdout.on("data", (data) => {
      if (!started && data.toString().includes("listening")) {
        started = true;
        resolve();
      }
    });
    serverProc.stderr.on("data", () => {});
    serverProc.on("error", reject);
    serverProc.on("exit", (code) => {
      if (!started) reject(new Error(`Server exited with code ${code}`));
    });
    setTimeout(() => {
      if (!started) reject(new Error("Server did not start within 5s"));
    }, 5000);
  });
}

function rpcRequest(method, params, id, headers) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: "2.0", method, params, id });
    const opts = {
      hostname: "127.0.0.1",
      port: PORT,
      path: "/",
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
        ...(headers || {}),
      },
    };
    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch (_e) { /* empty response is ok for 204 */ }
        resolve({ status: res.statusCode, body: parsed, raw });
      });
    });
    req.on("error", reject);
    req.end(body);
  });
}

function assert(name, condition, detail) {
  if (condition) {
    pass++;
    console.log(`  PASS  ${name}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? ` (${detail})` : ""}`);
  }
}

async function runTests() {
  console.log("MCP Protocol Tests");
  console.log("");

  // T037: initialize
  {
    const res = await rpcRequest("initialize", {}, 1);
    assert("initialize returns 200", res.status === 200);
    assert(
      "initialize has correct protocolVersion",
      res.body && res.body.result && res.body.result.protocolVersion === "2025-11-25",
      `got ${res.body && res.body.result && res.body.result.protocolVersion}`
    );
    assert(
      "initialize advertises tools capability",
      res.body && res.body.result && res.body.result.capabilities && "tools" in res.body.result.capabilities
    );
    assert(
      "initialize has serverInfo",
      res.body && res.body.result && res.body.result.serverInfo && res.body.result.serverInfo.name === "obo-demo-mcp"
    );
  }

  // T037: notifications/initialized (notification, no id)
  {
    const res = await rpcRequest("notifications/initialized", {}, undefined);
    assert("notifications/initialized returns 204", res.status === 204);
  }

  // T037 & T038: tools/list
  {
    const res = await rpcRequest("tools/list", {}, 2, { "MCP-Protocol-Version": "2025-11-25" });
    assert("tools/list returns 200", res.status === 200);
    const tools = res.body && res.body.result && res.body.result.tools;
    assert("tools/list returns an array", Array.isArray(tools));

    // T038: both tools advertised
    const names = (tools || []).map((t) => t.name).sort();
    assert(
      "tools/list advertises weather_lookup",
      names.includes("weather_lookup")
    );
    assert(
      "tools/list advertises database_query (even though policy forbids it)",
      names.includes("database_query")
    );

    // T038: both have inputSchema
    for (const tool of tools || []) {
      assert(
        `${tool.name} has inputSchema`,
        tool.inputSchema && tool.inputSchema.type === "object"
      );
    }
  }

  // T037: tools/call weather_lookup
  {
    const res = await rpcRequest("tools/call", { name: "weather_lookup", arguments: { city: "Warsaw" } }, 3, { "MCP-Protocol-Version": "2025-11-25" });
    assert("tools/call weather_lookup returns 200", res.status === 200);
    const result = res.body && res.body.result;
    assert(
      "weather_lookup returns content",
      result && Array.isArray(result.content) && result.content.length > 0
    );
    assert(
      "weather_lookup content mentions Warsaw",
      result && result.content && result.content[0] && result.content[0].text.includes("Warsaw")
    );
  }

  // T037: tools/call database_query (must be functional)
  {
    const res = await rpcRequest("tools/call", { name: "database_query", arguments: { sql: "SELECT * FROM customers" } }, 4, { "MCP-Protocol-Version": "2025-11-25" });
    assert("tools/call database_query returns 200", res.status === 200);
    const result = res.body && res.body.result;
    assert(
      "database_query returns content (functional, not a stub)",
      result && Array.isArray(result.content) && result.content.length > 0
    );
    assert(
      "database_query is not an error",
      result && !result.isError
    );
  }

  // T037: unknown method returns -32601
  {
    const res = await rpcRequest("nonexistent/method", {}, 5);
    assert("unknown method returns 200 with error", res.status === 200);
    assert(
      "unknown method error code is -32601",
      res.body && res.body.error && res.body.error.code === -32601
    );
  }

  // unknown tool returns isError
  {
    const res = await rpcRequest("tools/call", { name: "nonexistent_tool", arguments: {} }, 6);
    assert("unknown tool returns 200", res.status === 200);
    const result = res.body && res.body.result;
    assert(
      "unknown tool has isError: true",
      result && result.isError === true
    );
  }

  console.log("");
  if (fail > 0) {
    console.log(`${fail} failed, ${pass} passed`);
    process.exit(1);
  }
  console.log(`All ${pass} tests passed`);
}

(async () => {
  try {
    await startServer();
    await runTests();
  } catch (err) {
    console.error("Test harness error:", err);
    process.exit(1);
  } finally {
    cleanup();
  }
})();
