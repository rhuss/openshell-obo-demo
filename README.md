# OpenShell On-Behalf-Of demo

A runnable demo of agent security on [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell):
workload identity, delegated access, tool-level policy, and per-binary network
enforcement, all on a laptop with Podman.

Built for the talk *Securing AI Agents on Kubernetes: Identity, Sandboxes, and
MCP Tool Governance*, Code Europe 2026, Warsaw.

**[Slides (PDF)](agent-security-codeeurope-2026.pdf)** ·
[Resources and links](https://gist.github.com/rhuss/a2a815d81753ec91192174838413b9a5)

## What it shows

Five things, each one a single command you can run yourself:

1. **Default deny.** A sandbox reaches nothing it was not granted.
2. **Workload identity.** The sandbox gets a SPIFFE identity it cannot forge,
   issued by SPIRE after attestation, and the agent process cannot read it.
3. **Delegated access.** A protected service receives a token naming both the
   user and the sandbox (RFC 8693), minted per request at the proxy. The agent
   never holds a credential.
4. **Tool-level policy.** Two MCP tools on the same host, same port, same TLS
   session. One allowed, one refused, by tool name inside the JSON-RPC body.
5. **Per-binary isolation.** The same destination, reached by a different
   program, is refused. The audit record names the binary.

## Running it

Everything runs inside the Podman machine VM, not on macOS directly: SPIRE
`chmod`s its UNIX sockets, which fails on a virtiofs-shared filesystem and takes
the whole stack down with it.

```bash
podman machine ssh
cd <this repo>

export PATH="$HOME/.local/bin:$PATH"
export OBO_STATE_DIR=/var/tmp/obo-demo-state
export OPENSHELL_WORKTREE=$HOME/Development/OpenShell-demo

bash demo/bring-up.sh     # ~40s
bash demo/verify.sh       # eight tiers, exits 0 when the environment is sound
bash demo/teardown.sh
```

See [demo/README.md](demo/README.md) for the full setup, including the three
inference modes (`vertex`, `apikey`, and `none`, which still passes every
assertion on an agent-free path).

## Reading it

| | |
|---|---|
| [demo/ARCHITECTURE.md](demo/ARCHITECTURE.md) | How the pieces fit: gateway, supervisor, SPIRE, the token exchange |
| [demo/STAGE.md](demo/STAGE.md) | The live walkthrough, command by command, with what each one proves |
| [demo/RUNBOOK.md](demo/RUNBOOK.md) | Operating it: rebuilds, recovery, what breaks and why |
| [demo/policy/sandbox-policy.yaml](demo/policy/sandbox-policy.yaml) | The policy under test, annotated |
| [demo/providers/protected-service.yaml](demo/providers/protected-service.yaml) | The token exchange, declared rather than coded |

## Caveats

This is demo scaffolding, not a deployment pattern. The token issuer is a toy,
the SPIRE entry is registered by hand (on Kubernetes the SPIRE controller
manager does that for you), and the services it talks to are stubs. The
enforcement being demonstrated is real; everything around it is staging.

Pinned to OpenShell v0.0.116. Later releases move fast, and some of the flags
here have already changed.

## Licence

Apache 2.0.
