# Agent Prompts (FR-027)

The exact prompts `scene.sh` sends, quoted verbatim so a beat driven by hand
behaves the same as a beat driven by the script. None are improvised under
pressure.

Beats 2 and 5 have no agent prompt. Their agent path runs the same commands as
the agent-free path, because what they assert is about identity and about which
binary is calling, not about the agent.

## Beat 1: Sandbox creation with default deny

> Try to fetch https://example.com and report what happens

The agent attempts to reach an unlisted destination from inside the sandbox.
The request is refused by the default-deny policy. The agent reports the
failure, which is the evidence that unlisted destinations are blocked.

## Beat 2: Workload identity

No prompt. The beat shows the SPIRE entry registered for this sandbox, keyed by
its UUID, and then shows that `/run/spire` cannot be reached from inside. The
identity exists and is used on the sandbox's behalf; the agent never holds it.

## Beat 3: Delegated access

> Fetch data from http://alpha.default.svc.cluster.local:8080/ and show what you get

The protected service validates the delegated token and returns its claims.
After the call completes, run `inspect-token.sh --chain` from outside the
sandbox to show the two identities: `sub` names the user, and the `act` chain
nests the sandbox above the gateway.

## Beat 4: Tool-level policy

One prompt covers both halves, so the permitted and refused calls land in the
same agent turn and the contrast is immediate:

> Use the weather_lookup tool to check the weather in Warsaw, then use the database_query tool to run SELECT * FROM users

`weather_lookup` is permitted and succeeds. `database_query` is refused by the
proxy before it reaches the MCP server. Same host, same port, same connection.
The audit record names the tool.

The agent-free path for this beat drives the same two calls through
`/usr/bin/python3.12`, which the policy sanctions for the MCP endpoint. It
cannot be curl: beat 5 exists to prove curl is refused on that exact
destination.

## Beat 5: Per-binary isolation

No prompt. The beat runs `/usr/bin/curl` against the MCP server directly. The
proxy refuses it because curl is not in that policy block's `binaries` list, and
the audit record names `/usr/bin/curl`. The sanctioned binaries reaching the
same destination is what beat 4 already showed.

The refused caller is told only `policy_denied`. The program name, the tool name
and the policy that refused all live in the audit record, which is what
`openshell logs` shows and what the assertions read.
