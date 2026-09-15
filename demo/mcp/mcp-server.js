// MCP server for the OBO demo: Streamable HTTP, revision 2025-11-25.
// Advertises weather_lookup (policy-allowed) and database_query (policy-denied).
// Both tools are fully functional; the demo claims policy stops database_query,
// not that the tool is broken.

const http = require("http");

const PORT = Number(process.env.PORT || 8080);
const PROTOCOL_VERSION = "2025-11-25";

// ── Canned data ───────────────────────────────────────────────────────

// Real observations for 15 September 2026, the Code Europe talk date, taken
// from wttr.in so a glance out of the window does not contradict the demo.
// Nothing fetches these at runtime: the server is offline by design, which is
// also why the allowed tool cannot fail on stage.
const WEATHER = {
  warsaw: "Warsaw: 14°C, cloudy, wind 4 km/h NNW",
  krakow: "Kraków: 14°C, mist, wind 9 km/h W",
  "kraków": "Kraków: 14°C, mist, wind 9 km/h W",
  prague: "Prague: 14°C, sunny, wind 5 km/h SSW",
  berlin: "Berlin: 13°C, sunny, wind 6 km/h S",
  london: "London: 17°C, overcast, wind 11 km/h SSW",
  "new york": "New York: 18°C, clear, wind 13 km/h NNE",
  tokyo: "Tokyo: 27°C, patchy rain nearby, wind 31 km/h SSW",
};

const DB_ROWS =
  "id | name  | email\n" +
  "1  | Alice | alice@example.com\n" +
  "2  | Bob   | bob@example.com\n" +
  "3  | Carol | carol@example.com";

// ── Tool definitions (contracts/mcp-tools.md) ─────────────────────────

const TOOLS = [
  {
    name: "weather_lookup",
    description: "Look up the current forecast for a city",
    inputSchema: {
      type: "object",
      properties: { city: { type: "string" } },
      required: ["city"],
    },
  },
  {
    name: "database_query",
    description: "Run a read query against the customer database",
    inputSchema: {
      type: "object",
      properties: { sql: { type: "string" } },
      required: ["sql"],
    },
  },
];

// ── Tool handlers ─────────────────────────────────────────────────────

function handleWeatherLookup(args) {
  const city = String(args.city || "").toLowerCase();
  const forecast = WEATHER[city] || `${args.city || "Unknown"}: 20°C, clear skies, wind 5 km/h N`;
  return { content: [{ type: "text", text: forecast }] };
}

function handleDatabaseQuery(args) {
  const sql = String(args.sql || "SELECT * FROM customers");
  return {
    content: [{ type: "text", text: `Results for: ${sql}\n\n${DB_ROWS}` }],
  };
}

// ── JSON-RPC dispatch ─────────────────────────────────────────────────

function handleRpc(msg) {
  const method = msg.method;
  const id = msg.id;
  const params = msg.params || {};

  // Notifications have no id; they get 204 No Content
  const isNotification = id === undefined || id === null;

  if (method === "initialize") {
    return {
      status: 200,
      body: {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "obo-demo-mcp", version: "1.0.0" },
        },
      },
    };
  }

  if (method === "notifications/initialized") {
    return { status: 204, body: null };
  }

  if (method === "tools/list") {
    return {
      status: 200,
      body: { jsonrpc: "2.0", id, result: { tools: TOOLS } },
    };
  }

  if (method === "tools/call") {
    const toolName = params.name;
    const toolArgs = params.arguments || {};

    if (toolName === "weather_lookup") {
      return {
        status: 200,
        body: { jsonrpc: "2.0", id, result: handleWeatherLookup(toolArgs) },
      };
    }
    if (toolName === "database_query") {
      return {
        status: 200,
        body: { jsonrpc: "2.0", id, result: handleDatabaseQuery(toolArgs) },
      };
    }

    // Unknown tool
    return {
      status: 200,
      body: {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: `Unknown tool: ${toolName}` }],
          isError: true,
        },
      },
    };
  }

  // Unknown method
  if (isNotification) {
    return { status: 204, body: null };
  }
  return {
    status: 200,
    body: {
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `Method not found: ${method}` },
    },
  };
}

// ── HTTP server ───────────────────────────────────────────────────────

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
    if (Buffer.concat(chunks).length > 1024 * 1024) {
      throw new Error("request body too large");
    }
  }
  return Buffer.concat(chunks).toString("utf8");
}

function sendJson(res, status, body) {
  if (body === null) {
    res.writeHead(status);
    res.end();
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  try {
    // Health check
    if (req.url === "/healthz" && req.method === "GET") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("ok\n");
    }

    if (req.method !== "POST") {
      return sendJson(res, 405, {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32600, message: "Method not allowed; use POST" },
      });
    }

    const body = await readBody(req);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch (_e) {
      return sendJson(res, 400, {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: "Parse error" },
      });
    }

    const result = handleRpc(msg);
    return sendJson(res, result.status, result.body);
  } catch (err) {
    console.error("MCP server error:", err);
    return sendJson(res, 500, {
      jsonrpc: "2.0",
      id: null,
      error: { code: -32603, message: "Internal error" },
    });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`MCP server listening on ${PORT}`);
});
