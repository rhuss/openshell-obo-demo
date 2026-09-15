# OpenShell On-Behalf-Of Demo

Five beats demonstrating sandbox security, workload identity, delegated access,
tool-level policy, and per-binary isolation using NVIDIA OpenShell.

## Everything runs inside the Podman machine VM

Not on macOS directly. SPIRE creates UNIX sockets and then `chmod`s them, which
fails with `invalid argument` on any filesystem shared from a macOS host
(virtiofs). That crashes the SPIRE server on startup and cascades into every
other component, so the demo runs inside the VM and keeps its state on a
VM-native path.

Three environment variables are mandatory in every shell that runs a demo
script. None of them has a usable default here, because inside the VM `$HOME`
is `/var/home/core`:

```bash
podman machine ssh

export PATH="$HOME/.local/bin:$PATH"
export OBO_STATE_DIR=/var/tmp/obo-demo-state          # must be VM-native, not the repo
export OPENSHELL_WORKTREE=$HOME/Development/OpenShell-demo

cd $HOME/talks/codeeurope-agent-security-2026
```

Pointing `OBO_STATE_DIR` at the repo puts SPIRE's socket back on virtiofs and
reproduces the crash above.

## Preflight Checklist

Before walking on stage, confirm every item:

- [ ] Podman running with a machine (`podman machine info`)
- [ ] Inside `podman machine ssh`, with the three variables above exported
- [ ] OpenShell CLI on PATH inside the VM (`openshell --version` reports 0.0.116)
- [ ] Pinned worktree checked out at `v0.0.116` (`d1155aa7`), matching the CLI
- [ ] Node 22 in the VM for unit tests (`node --version`)
- [ ] An inference backend: gcloud ADC present for Vertex, or `ANTHROPIC_API_KEY`
      exported. See [Inference](#inference)
- [ ] `bash demo/bring-up.sh` reports all nine components ready with >= 5400s
      credential validity
- [ ] `bash demo/verify.sh` passes every tier
- [ ] Terminal font size set for projection (test with `./inspect/inspect-token.sh --chain`)
- [ ] Presenter notes open (`demo/agent/prompts.md`)

## Quick Start

From the repo root, inside the VM, with the variables above exported:

```bash
bash demo/bring-up.sh        # Green room: bring everything up
bash demo/scene.sh           # Stage: run the five beats
bash demo/teardown.sh        # After: clean up everything
```

## Inference

`OBO_INFERENCE` selects the backend. The default, `auto`, takes Vertex when the
gcloud ADC is present, then a static Anthropic key, then nothing.

```bash
export OBO_INFERENCE=vertex     # gateway mints and rotates a one-hour GCP token
export OBO_INFERENCE=apikey     # needs ANTHROPIC_API_KEY exported before bring-up
export OBO_INFERENCE=none       # every beat still passes on its agent-free path
```

Vertex is the stronger claim on stage: the agent is pointed at
`https://inference.local` with a placeholder key, and the gateway strips it and
injects a real short-lived GCP token on the way out, so the sandbox never holds
a usable credential.

Do not set `CLAUDE_CODE_USE_VERTEX=1`. It makes Claude Code talk to Vertex
directly and hunt for GCP credentials through ADC and the metadata service,
neither of which the sandbox exposes.

Single beat: `./scene.sh 3` (agent path) or `./scene.sh 3 --curl` (without agent).

List beats: `./scene.sh --list`.

Verify: `./verify.sh` (full), `./verify.sh --unit` (no infrastructure),
`./verify.sh --no-inference` (hostile network).

## Manual vs. Scripted

Every manual step is a single command completing under 20 seconds (FR-024, FR-025).

| Step | Type | Command | Reason |
|------|------|---------|--------|
| Environment bring-up | Scripted | `./bring-up.sh` | Multi-component, idempotent, >20s |
| Run all beats | Scripted | `./scene.sh` | Pacing, evidence display |
| Run single beat | Manual | `./scene.sh <n>` | Recovery, <20s |
| Run beat via curl | Manual | `./scene.sh <n> --curl` | Fallback, <20s |
| Inspect delegation | Manual | `./inspect/inspect-token.sh --chain` | On-demand evidence, <5s |
| Inspect token phase | Manual | `./inspect/inspect-token.sh --phase <p>` | Debugging, <5s |
| Verify all beats | Scripted | `./verify.sh` | Full regression, >20s |
| Unit tests only | Scripted | `./verify.sh --unit` | Pre-flight check, <10s |
| Teardown | Scripted | `./teardown.sh` | Multi-component cleanup |

## Beat Reference

| Beat | Claim | Needs Inference |
|------|-------|-----------------|
| 1 | Sandbox exists with default deny: unlisted destinations refused | No |
| 2 | Workload identity exists; agent cannot reach Workload API | No |
| 3 | Protected request succeeds with credential naming both identities | No (custody evidence: yes) |
| 4 | Policy allows one tool, refuses another on same destination | No |
| 5 | Unsanctioned program refused; sanctioned program succeeds | No |

All five beats work on their agent-free path with no inference service. Beats 2
and 5 have no separate agent path: their agent command delegates to the
agent-free one, because what they assert is about identity and binaries rather
than about the agent. Beat 3 includes optional credential custody evidence that
requires inference and is independently skippable.

Beat 4's agent-free path uses `/usr/bin/python3.12`, not curl. Beat 5 exists to
prove curl is refused on that exact destination, so both cannot hold at once;
the policy sanctions Python for the MCP endpoint instead. Python lives under
`/usr`, which the filesystem policy mounts read-only, so the agent cannot swap
the binary out from under the rule.

Policy `binaries` entries are matched against `/proc/<pid>/exe`, so they must
name the resolved target: `/usr/bin/python3.12`, never the `/usr/bin/python3`
symlink.

## Fallback Procedure

### If a single beat fails

Run the next beat. Beats are independent given a ready environment. Recovery
takes under 15 seconds.

```bash
./scene.sh <next-beat-number>
```

### If bring-up fails

Check the readiness table for the failing component and its reason. Then:

1. Try `./teardown.sh && ./bring-up.sh` for a clean restart
2. If SPIRE components fail, check Podman machine status: `podman machine info`
3. If the gateway fails, check that no other process holds port 8101

### If the inference service is unreachable

Switch every beat to the curl path. All five core assertions pass without inference.

```bash
./scene.sh --curl         # or per-beat: ./scene.sh 3 --curl
```

### Point of abandonment

If `./bring-up.sh` fails after a teardown-and-retry cycle, switch to the recorded
fallback. Do not debug on stage.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Credential validity under 5400s | Issuer patch lost; upstream 1800s in effect | Rebuild issuer: `podman build -t obo-demo-issuer demo/issuer/` |
| `chmod ... invalid argument`, SPIRE crashes | `OBO_STATE_DIR` is on a macOS-shared path | Use a VM-native path such as `/var/tmp/obo-demo-state` |
| `OpenShell worktree not found` | `OPENSHELL_WORKTREE` unset; `$HOME` in the VM is `/var/home/core` | Export it explicitly |
| `inspect-token.sh` reports no token | No beat has run, or debug listener down | Run beat 3 first, check issuer container logs |
| Tool refusal names no tool | Policy missing `protocol: mcp` | Check `demo/policy/sandbox-policy.yaml` |
| `curl` succeeds when it should fail on MCP | `/usr/bin/curl` in the `mcp_tools` binaries | Check policy; this silently destroys beat 5. Curl is deliberately permitted in the `protected_service` block, which is a different host |
| Agent cannot reach inference | Venue network blocks egress | `OBO_INFERENCE=none`; every beat still passes agent-free |
| `token_unavailable` from the agent | `CLAUDE_CODE_USE_VERTEX` is set somewhere | Vertex goes through `inference.local`, not the metadata service |
| `ssrf_denied`, `declared endpoint check failed` | Almost always DNS: a container has the wrong network alias | Bring-up replaces mis-aliased containers; re-run it |
| `invalid_client` on the token exchange | The gateway's SPIRE entry does not match, or a stale one lingers | Bring-up prunes and re-registers; re-run it |
| Changed env or policy has no effect | Both are applied only at sandbox creation | `openshell sandbox delete obo-demo`, then re-run bring-up |
| SPIRE agent won't start, `certificate signed by unknown authority` | Environment sat idle; the join-token SVID expired and cannot re-attest | `teardown.sh && bring-up.sh`. Restarting containers cannot fix this, and bring-up alone will not either |
| Gateway FAILED with `agent.sock does not exist` | Same cause: the SPIRE agent crashed, so the socket was never created | As above. Read the agent log, not the gateway log |

## Recorded Fallback

<!-- T067: asciinema recording of full successful run at demo/recordings/full-run.cast -->

If the live demo cannot proceed, play the recorded fallback:

```bash
asciinema play demo/recordings/full-run.cast
```

## Architecture

```
Host
 +-- bring-up.sh (green room)
 +-- scene.sh (stage)
 +-- verify.sh (rehearsal)
 |
 +-- Podman network: openshell
      +-- spire-server + oidc-provider
      +-- spire-agent
      +-- token-issuer (port 8097, debug: unix socket)
      +-- protected-service (port 8099)
      +-- mcp-server (port 8100)
      +-- gateway (port 8101)
      +-- sandbox: obo-demo
```

## Files

| Path | Purpose |
|------|---------|
| `bring-up.sh` | Idempotent environment setup |
| `scene.sh` | Stage runner with beat pacing |
| `verify.sh` | Non-interactive regression harness |
| `teardown.sh` | Clean removal of all demo state |
| `ARCHITECTURE.md` | What each piece is, who issues which identity, where the exchange happens |
| `STAGE.md` | Commands to type live, with what to say |
| `RUNBOOK.md` | Current status, known gaps, and the debugging history behind them |
| `lib/common.sh` | Shared environment and helpers |
| `lib/beats.sh` | Beat definitions (data model) |
| `issuer/token-issuer.js` | Patched token issuer with act claims |
| `issuer/Containerfile` | Issuer container image |
| `mcp/mcp-server.js` | Streamable HTTP MCP server |
| `mcp/Containerfile` | MCP server container image |
| `policy/sandbox-policy.yaml` | Sandbox policy (no deny rules) |
| `providers/protected-service.yaml` | Token exchange provider profile |
| `inspect/inspect-token.sh` | Token inspection with --phase, --chain |
| `agent/mcp-config.json.template` | MCP client config template |
| `agent/prompts.md` | Presenter instructions per beat |
| `tests/` | Unit and e2e test files |
