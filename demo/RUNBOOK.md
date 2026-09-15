# OBO Demo Runbook

How to bring the demo up yourself, what currently works, and what does not.

Status as of 2026-09-14: **working.** Nine of nine components come up and
`verify.sh` passes every tier: unit, structural, policy, isolation, custody,
beat independence, path equivalence, integration. All five beats pass on both
the agent path and the agent-free path, with inference through Vertex.

## Why it runs in the VM

The demo runs inside the Podman machine VM, not on macOS directly.

SPIRE creates its API socket in a bind-mounted directory and then `chmod`s it.
On macOS that directory reaches the VM over virtiofs, where `chmod` on a unix
socket returns `EINVAL`, so the SPIRE server crashes on startup and every other
component fails after it. Filed upstream as
[NVIDIA/OpenShell#3298](https://github.com/NVIDIA/OpenShell/issues/3298).

Inside the VM everything is native Linux: chmod works, Landlock is active
(kernel 7.0.11, `lsm` includes `landlock`), and the paths podman bind-mounts are
real. On stage this is an ssh session, which looks identical to a local terminal
from the audience's side.

## One-time setup

Already done on this machine. Repeat only on a fresh laptop.

```shell
# 1. Pinned OpenShell worktree (read-only, never modified by the demo)
git -C ~/Development/OpenShell worktree add ~/Development/OpenShell-demo \
  d1155aa70042d3e2ee49dbfa15346b108b7c1d92

# 2. OpenShell CLI inside the VM, matching the pin (v0.0.116)
podman machine ssh
  mkdir -p ~/.local/bin && cd /tmp
  curl -fLs -o os.tgz https://github.com/NVIDIA/OpenShell/releases/download/v0.0.116/openshell-aarch64-unknown-linux-musl.tar.gz
  tar xzf os.tgz && install -m0755 openshell ~/.local/bin/openshell

# 3. Node inside the VM, for the unit tier (matches the sandbox image)
  V=v22.22.1
  curl -fsSL -o node.tar.xz "https://nodejs.org/dist/$V/node-$V-linux-arm64.tar.xz"
  tar xf node.tar.xz && install -m0755 "node-$V-linux-arm64/bin/node" ~/.local/bin/node
```

The pin is the **v0.0.116 release**, not an arbitrary `main` commit. A release is
the only point where the worktree scripts, published gateway images, and a
published CLI binary all exist and agree. `main` publishes per-commit images but
no CLI, and a newer CLI fails against an older gateway with
`workspace_scope is required`.

## Running the demo

### On stage: walkthrough.sh

`bash demo/walkthrough.sh` types each command at a real prompt and waits for a
keypress before running it. `walkthrough.sh <n>` re-runs a single beat, which is
the recovery path if one misfires. `DEMO_AUTO=1 TYPE_SPEED=0` rehearses the
whole thing with no waits.

It uses `bat` to show a slice of the provider profile. That is a static binary
in the VM's `~/.local/bin`, installed by hand rather than through rpm-ostree,
so it does not survive a VM rebuild from scratch:

```shell
V=v0.26.1; A=bat-${V}-aarch64-unknown-linux-musl
curl -sSL "https://github.com/sharkdp/bat/releases/download/${V}/${A}.tar.gz" \
  | tar xz -C /var/tmp && install -m755 /var/tmp/${A}/bat ~/.local/bin/bat
```

The walkthrough falls back to plain numbered output if `bat` is absent, so a
missing binary degrades rather than breaks.

See [STAGE.md](./STAGE.md) for the commands with what to say alongside them.

### Unattended: scene.sh

Five beats, six minutes. `scene.sh` runs them in order and waits for a keypress
between each. Use it to rehearse or as the fallback if typing goes wrong; it
prints PASS or FAIL per beat rather than showing the commands.

```shell
bash demo/scene.sh              # all five, paced
bash demo/scene.sh 3            # one beat, agent path
bash demo/scene.sh 3 --curl     # one beat, agent-free path
bash demo/scene.sh --list       # the five claims, for a last look before going on
```

Each beat prints its claim, runs the command, shows the evidence, then prints
PASS or FAIL. Nothing needs to be typed live.

### Beat 1: the sandbox refuses what is not listed

Claim: *the sandbox exists with default deny; unlisted destinations are refused.*

The agent is asked to fetch `https://example.com`. It cannot, and says so.
Evidence is the sandbox in `sandbox list` plus the refusal itself. The point to
make: nothing was blocked by name, the destination simply was not on the list.

### Beat 2: it has an identity it cannot reach

Claim: *the sandbox has a workload identity the agent cannot access.*

Shows the SPIRE entry for this sandbox, keyed by its UUID, then shows that
`/run/spire` is not reachable from inside. The identity exists and is used on
the sandbox's behalf; the agent never holds it. No agent path here: there is
nothing for the agent to do.

### Beat 3: one request, two identities

Claim: *a protected request succeeds with a credential naming both the user and
the sandbox.*

The agent fetches the protected service. It works. Then the delegation chain:

```shell
bash demo/inspect/inspect-token.sh --chain          # both phases
bash demo/inspect/inspect-token.sh --phase final    # just the final token
```

This is the beat the talk is built on, and the slowest one to read aloud. Point
at `sub: demo-user` and at the `act` chain nesting the sandbox above the
gateway: the protected service knows who asked and what acted.

Optional custody evidence follows, showing the agent holds only an
`openshell:resolve:env:` placeholder and that the placeholder is not a usable
credential. It needs inference, and it is independently skippable.

### Beat 4: same destination, different tool

Claim: *policy allows one tool and refuses another on the same destination.*

`weather_lookup` succeeds, `database_query` is refused. Same host, same port,
same connection. The refusal names the tool, not the destination.

### Beat 5: same destination, different program

Claim: *an unsanctioned program is refused; the sanctioned one succeeds.*

`curl` to the MCP host is refused and the deny record names `/usr/bin/curl`.
The closing line: the policy is about *who is calling*, not only where they are
going.

### If a beat fails on stage

Go to the next one. Beats are independent given a ready environment, recovery is
under fifteen seconds, and `scene.sh` never unwinds earlier beats.

```shell
bash demo/scene.sh <next>
bash demo/scene.sh <n> --curl    # if the agent is the problem, not the mechanism
```

If the venue network blocks inference, every beat still passes agent-free. If
bring-up fails after one teardown-and-retry, switch to the recording. Do not
debug on stage.

### Before walking on

```shell
bash demo/bring-up.sh      # nine ready, credential validity >= 5400s
bash demo/verify.sh        # exit 0
bash demo/scene.sh --list  # the claims, in order
```

The exact agent prompts are in `demo/agent/prompts.md`, worded so none has to be
improvised under pressure.

## After more than a few hours idle: rebuild, do not resume

A reboot is survivable. Being left for a day or two is not, and the failure is
loud but misleading: the gateway refuses to start, the sandbox is never
created, three components report FAILED, and the real cause is two layers down
in the SPIRE agent log.

```
Agent crashed: could not open attestation stream to SPIRE server:
  x509svid: could not verify leaf certificate: certificate signed by unknown authority
Keys recovered, but no SVID found
```

The agent attests with a join token, which is single-use and non-reattestable,
and its SVID has a finite life. Once that expires there is no path back:
restarting containers cannot re-establish trust, and `bring-up.sh` on its own
will not repair it because the state on disk is the problem.

Measured on a two-day-old environment: `bring-up.sh` alone failed; a teardown
first rebuilt everything green in 39 seconds.

```shell
bash demo/teardown.sh && bash demo/bring-up.sh
bash demo/verify.sh
```

If the laptop slept overnight, do this before anything else. It costs 40
seconds and removes the only failure mode that cannot be fixed on stage.

## After a reboot

The Podman machine has no launch agent, so it does not come back on its own,
and every container is created with `RestartPolicy=no` and comes back `exited`.
Nothing is lost: `OBO_STATE_DIR` lives on `/var/tmp`, which is on the VM's
persistent root filesystem (`/tmp` is tmpfs and would not survive), and the
container images stay cached.

```shell
podman machine start          # ~12s, on macOS, not inside the VM
podman machine ssh

export PATH="$HOME/.local/bin:$PATH"
export OBO_STATE_DIR=/var/tmp/obo-demo-state
export OPENSHELL_WORKTREE=$HOME/Development/OpenShell-demo
export OPENSHELL_GATEWAY_ENDPOINT=http://127.0.0.1:8101
cd $HOME/talks/codeeurope-agent-security-2026

bash demo/bring-up.sh         # ~14s, restarts the stopped containers
bash demo/verify.sh           # confirm, check the exit code
```

`OPENSHELL_GATEWAY_ENDPOINT` is what lets every `openshell` command be typed
bare, with no `--gateway-endpoint` flag and no gateway registration step. It is
in the VM's `~/.bashrc`, so a fresh shell already has it.

Measured after a full machine stop and start: nine components ready in 14s and
every verify tier green. Bring-up restarts the existing containers rather than
recreating them, so this is a restart, not a rebuild.

If anything looks wrong, rebuild from nothing instead of debugging:

```shell
bash demo/teardown.sh && bash demo/bring-up.sh    # ~7s with images cached
```

The one thing worth protecting is the container image cache. The images are
what make this fast; losing them turns a 7 second rebuild into however long the
pulls take on the venue network.

## Bring-up

Everything below runs inside the VM. The three environment variables are
required every time.

```shell
podman machine ssh

export PATH="$HOME/.local/bin:$PATH"
export OBO_STATE_DIR=/var/tmp/obo-demo-state
export OPENSHELL_WORKTREE=$HOME/Development/OpenShell-demo
cd $HOME/talks/codeeurope-agent-security-2026

bash demo/bring-up.sh
```

`OBO_STATE_DIR` must be a VM-native path. Pointing it at the repo puts SPIRE's
socket back on virtiofs and reproduces the crash above.

Expected final line:

```
Ready (credential validity: 118 minutes)
```

Bring-up is idempotent. Re-run it freely; it repairs rather than duplicating. It
replaces containers built from the wrong image, resets gateway state when the
pin changes, and re-mints the subject token when validity drops below 90 minutes.

### Verifying

```shell
bash demo/verify.sh --unit              # no infrastructure needed
bash demo/verify.sh --no-inference      # skips beats needing Anthropic
bash demo/verify.sh                     # everything
```

`--unit --strict` treats a missing test file as a failure. Use it as the final
gate; a skipped test is a test that was never written.

### Teardown

```shell
bash demo/teardown.sh
```

## Known gaps

Nothing here blocks the demo any more. Kept because the reasoning is worth
having when something breaks, and because the section below records how each
was actually diagnosed.

Still genuinely open: no asciinema recording exists (T067), so the "play the
recorded fallback" line below has nothing behind it; timing against the six
minute budget and projector legibility have not been measured.

### Working

- All nine components reach ready
- Every verify tier passes; `verify.sh` exits 0
- All five beats, on both the agent path and the agent-free path
- Inspection isolation: the debug surface is genuinely unreachable from the
  sandbox. It is a UNIX socket inside the issuer container, so there is no TCP
  port to reach. All three negative assertions pass.
- Binary denial: `curl` to the MCP host is refused and the gateway deny record
  names `/usr/bin/curl` and the policy that refused it.
- Inference over Vertex through `inference.local`.

Two of these were failing for a test reason rather than a real one: `curl -sf`
discards the proxy's `{"error":"policy_denied"}` body, so both tests failed with
nothing to assert on while the denial itself worked. They now use
`--fail-with-body`, and the binary name is read from `openshell logs` where it
actually lives, rather than from curl's output where it never appears.

### Inference

`OBO_INFERENCE` picks the backend. `auto` (the default) takes Vertex when the
gcloud ADC is present, then a static key, then none.

```shell
export OBO_INFERENCE=vertex     # gateway mints and rotates the token
export OBO_INFERENCE=apikey     # needs ANTHROPIC_API_KEY before bring-up
```

Vertex is the better story on stage and it works today. The agent is pointed at
`https://inference.local` with `ANTHROPIC_API_KEY=unused`; the gateway strips
that placeholder and injects a real one-hour GCP token on the way out, so the
sandbox holds no usable credential at any point. `GOOGLE_VERTEX_AI_TOKEN` is
visible inside the sandbox but is only an `openshell:resolve:env:` placeholder.

Do not set `CLAUDE_CODE_USE_VERTEX=1`. That makes Claude Code talk to Vertex
directly and hunt for GCP credentials through ADC and the GCE metadata service,
neither of which the sandbox exposes, and it fails with
`Could not refresh access token: {"error":"token_unavailable"}`. The metadata
emulator belongs to the `google-cloud` provider, not to this path.

With no backend at all the agent reports `Not logged in · Please run /login`, so
any beat whose sanctioned path is the `claude` binary cannot succeed.

### Beats 4 and 5: resolved by sanctioning a second binary

FR-010 wants every beat to have an agent-free alternative, and beat 5 exists to
prove `curl` is refused on the MCP endpoint. Both cannot hold while beat 4's
alternative is also `curl` against that same host and port.

Beat 4 now drives MCP through `/usr/bin/python3.12`, which the policy sanctions
alongside `/usr/local/bin/claude`. Python lives under `/usr`, which the
filesystem policy mounts read-only, so the agent cannot swap the binary out from
under the rule. Beat 5 is untouched and `curl` stays the closing argument.

The policy must name the kernel-resolved path. `binaries` entries are matched
against `/proc/<pid>/exe`, so `/usr/bin/python3` (a symlink to `python3.12`)
would never match. The deny record spells this out in a SYMLINK HINT.

### What the delegated path needed

Beat 3 went through four distinct failures, each hidden behind the previous one.
Recorded here because none of them is guessable from the symptom:

1. `not permitted by policy`. The policy had no entry for the protected
   service. Added as its own `network_policies` block. `binaries` is scoped per
   block, so `curl` is permitted there while staying refused on MCP.
2. `ssrf_denied: declared endpoint check failed`, which is really
   `DNS resolution failed`. The `alpha` and `mcp` containers were running with
   the upstream compose's `*.demo.local` aliases, and bring-up reused them
   because it only ever compared the image. `ensure_component` now compares the
   network alias too, since an alias can only be set at creation.
3. `invalid_client`. The SPIRE agent answered "no identity issued" for the
   gateway. The upstream `register-gateway.sh` selects on `unix:uid:$(id -u)`,
   but the agent reads `/proc/<pid>/status` through its own user namespace,
   which under rootless Podman maps this host's UID to 0.
4. `unsupported_intermediate_audience`. Correcting that to `unix:uid:0` matched
   far too much: every rootless container process attests as uid 0, so the
   sandbox supervisor picked up the gateway's identity and offered it as the
   intermediate audience. Fixed by selecting on the container label,
   `docker:label:openshell.spiffe-demo:gateway`, which is what the sandbox
   entries already do.

A stale gateway entry from an earlier run is not cleaned up automatically. If
the exchange misbehaves, check for duplicates:

```shell
podman exec openshell-spiffe-demo-spire-server /opt/spire/bin/spire-server \
  entry show -socketPath /run/spire/server/private/api.sock | grep -A6 gateway/demo
```

### Beat 2: looked up the wrong SPIFFE ID

`beat_2_assert` built the ID from the sandbox *name*, but SPIRE entries are
registered under the gateway's sandbox *UUID*, so it searched for an ID that has
never existed and failed with no output. `sandbox_uuid` in `common.sh` resolves
the name first, and an unresolvable name now fails loudly rather than silently.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `chmod ... invalid argument`, SPIRE crashes | `OBO_STATE_DIR` is on a macOS-shared path. Use a VM-native one |
| Every component fails after SPIRE | Root cause is SPIRE; read `$OBO_STATE_DIR/spire-server-start.log` |
| `OpenShell worktree not found` | `OPENSHELL_WORKTREE` unset. Inside the VM `$HOME` is `/var/home/core`, so the default is wrong |
| `unknown field` compute_driver | Gateway image and scripts disagree. See [#3297](https://github.com/NVIDIA/OpenShell/issues/3297) |
| `migration N was previously applied` | Gateway state from a different pin. Bring-up resets this automatically |
| `relay open timed out`, phase still Ready | Sandbox JWT expired. Bring-up now sets `ttl_secs = 0`; if it recurs, check `$OBO_STATE_DIR/gateway/gateway.toml` |
| `workspace_scope is required` | CLI and gateway versions differ. Both must be v0.0.116 |
| `not permitted by policy` | The destination or the calling binary is missing from that policy block. `binaries` is per block, and it matches the kernel-resolved path, not a symlink |
| `ssrf_denied`, `declared endpoint check failed` | Almost always DNS. Check the container's network alias matches the name the demo uses |
| `invalid_client` on the exchange | The gateway's SPIRE entry does not match. See "What the delegated path needed" |
| `unsupported_intermediate_audience` | The supervisor picked up the wrong SVID, usually a gateway entry with an over-broad selector |
| `token_unavailable` from the agent | `CLAUDE_CODE_USE_VERTEX` is set somewhere. The Vertex path goes through `inference.local`, not the metadata service |
| Changed env or policy has no effect | Bring-up reuses an existing sandbox and only applies both at creation. `openshell sandbox delete obo-demo`, then re-run |

## Useful commands

```shell
# Inside the VM, with PATH and endpoint set
OS="openshell --gateway-endpoint http://127.0.0.1:8101"

$OS sandbox list
$OS sandbox exec --name obo-demo --no-tty -- echo hello
$OS policy get obo-demo
$OS logs obo-demo

podman ps -a --filter name=openshell-spiffe-demo
podman logs openshell-spiffe-demo-gateway
podman logs openshell-spiffe-demo-issuer

# Decode the most recent delegated token
bash demo/inspect/inspect-token.sh --chain
```

Logs from delegated startup scripts land in `$OBO_STATE_DIR`:
`spire-server-start.log`, `spire-agent-start.log`, `gateway-start.log`,
`sandbox-create.log`, `policy-get.log`, `sandbox-exec-check.log`.
