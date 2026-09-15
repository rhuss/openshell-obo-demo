# Stage Script

Everything below is a real `openshell`, `podman` or `claude` command. No demo
scripts on stage: the point is that the audience sees the actual UX.

**Driving it semi-automatically:** `bash demo/walkthrough.sh` types each command
out at a real prompt and waits for a keypress before running it. Same commands
as below, nothing hidden, no 200-character line to mistype on stage.

```shell
bash demo/walkthrough.sh          # act 0, then all five beats
bash demo/walkthrough.sh act0     # just the live setup
bash demo/walkthrough.sh 4        # re-run one beat, the recovery path
DEMO_AUTO=1 TYPE_SPEED=0 bash demo/walkthrough.sh    # rehearse with no waits
```

It assumes the green-room reset below has happened, because Act 0 really does
create those objects.

A faint `⏎` marks each pause: the script is waiting for you, not stuck.

**Press `s` at any pause** for a shell carrying the demo's environment (`$SID`,
`$TOKEN`, `$MCP`, the gateway endpoint). Ctrl-D returns, and the pending command
is reprinted so you can see what runs next.

**To show things from inside the sandbox**, which is more convincing than
`exec`-ing one command at a time:

```shell
openshell sandbox exec --name obo-demo --tty -- bash -i
```

```
sandbox@sandbox-obo-demo:~$ curl -sS http://mcp.default.svc.cluster.local:8080/healthz
{"detail":"GET mcp...:8080/healthz not permitted by policy","error":"policy_denied"}
```

Inside that shell, run the agent with **`--bare`**:

```shell
sandbox@sandbox-obo-demo:~$ claude --bare
```

Plain `claude` fails with *"Unable to connect to Anthropic services"*. That is
not a broken sandbox: the environment is correct, `ANTHROPIC_BASE_URL` really is
`https://inference.local`. Claude Code runs a startup connectivity check against
`api.anthropic.com` that ignores the base URL, and the policy refuses it, as it
should. `--bare` skips that check and uses the key directly, which the gateway
then strips.

`exit` leaves the sandbox. The prompt says `sandbox@sandbox-obo-demo`, so the
room can see where you are, and **enforcement still holds from an interactive
shell**: curl is refused with bash in the ancestry exactly as it is through
`exec`. Verified.

Not `openshell sandbox connect`. It exists and looks like the right command, but
it hung in every attempt here and was never made to work. Use the line above.

The commands run without section banners and without reporting exit codes. Most
of what follows is *supposed* to fail, so an "(exit 2)" under a refusal makes a
working demonstration look broken.

Background (who issues what, where the exchange happens):
[ARCHITECTURE.md](./ARCHITECTURE.md). Read once before rehearsing.

---

## Green room, before the room fills

**Inside the VM, never from the Mac.** From the Mac the state lands in the wrong
place and SPIRE dies.

```shell
podman machine ssh
cd $HOME/talks/codeeurope-agent-security-2026

bash demo/teardown.sh && bash demo/bring-up.sh     # ~40s. Rebuild, never resume
bash demo/verify.sh                                # exit 0
```

Now clear the OpenShell layer, so every command in Act 0 is real:

```shell
openshell sandbox delete obo-demo
until ! openshell sandbox list 2>/dev/null | grep -q obo-demo; do sleep 1; done
openshell inference delete
openshell provider delete obo-user-token obo-demo obo-vertex
openshell provider profile delete obo-demo
```

Set the MCP config (beat 4 needs it, too long to type live), then clear the
screen:

```shell
source demo/env.sh     # gateway endpoint, project, region, model, $MCP
clear
```

`env.sh` derives everything: the project from your active gcloud config, the ADC
home by probing for the credentials file. That keeps your project name off the
screen, since the commands below show `$VERTEX_PROJECT_ID` rather than its
value.

---

## Act 0: build it live

**Say:** let me build this in front of you, so you see what the platform asks
of an operator.

```shell
export OPENSHELL_GATEWAY_ENDPOINT=http://127.0.0.1:8101
```
> Point the CLI at the gateway. Nothing after this needs a flag.

```shell
TOKEN=$(curl -fsS http://127.0.0.1:8097/demo-subject-token | jq -r .access_token)
```
> **Say:** the user's token. Here it comes from a demo issuer; in your world
> this is what your IdP hands you after a login.

```shell
openshell provider profile import -f demo/providers/protected-service.yaml
bat demo/providers/protected-service.yaml
```
> **Say:** this file declares the token exchange. It is a declaration, not code.
>
> `bat` opens it in a pager, so walk it live: the two credentials and why one of
> them has no `auth_style`, the token endpoint, the SPIFFE client assertion
> where a client secret would normally go, and `audience_overrides` at the
> bottom. **`q` to quit** and the walkthrough continues.

```shell
openshell provider create --name obo-user-token --type obo-demo \
  --credential subject_token="$TOKEN"
```
> **Say:** I hand the user's token to the gateway once. It never enters the
> sandbox — the profile marks it non-injectable.

```shell
HOME=$GCLOUD_ADC_HOME openshell provider create --name obo-vertex \
  --type google-vertex-ai --from-gcloud-adc \
  --config VERTEX_AI_PROJECT_ID=$VERTEX_PROJECT_ID \
  --config VERTEX_AI_REGION=$VERTEX_REGION
```
> **Say:** the inference credential. `--from-gcloud-adc` reads the file itself,
> so the refresh token never passes through this shell, my history, or this
> recording.

```shell
openshell inference set --provider obo-vertex --model $VERTEX_MODEL --no-verify
```
> **Say:** the agent will talk to `inference.local`. The gateway holds the real
> credential and injects it on the way out.

```shell
openshell sandbox create --name obo-demo \
  --provider obo-user-token --provider obo-vertex \
  --env ANTHROPIC_BASE_URL=https://inference.local \
  --env ANTHROPIC_API_KEY=unused \
  --policy demo/policy/sandbox-policy.yaml \
  --keep --detach --no-tty -- sleep infinity
```
> **Say:** two credentials, and the agent never holds either. Policy and
> environment can only be set here, at creation. A running sandbox cannot be
> talked into a wider policy.
>
> **If asked about `ANTHROPIC_API_KEY=unused`:** it satisfies Claude Code's own
> login check, nothing more. Remove it and the agent answers `Not logged in`
> before it sends anything. The value is discarded by the gateway, which
> attaches the real GCP token on the way out. Two credential-shaped values are
> visible in that sandbox and both are worthless there: this one, and
> `GOOGLE_VERTEX_AI_TOKEN`, which is a resolve-time placeholder.

```shell
SID=$(openshell sandbox list --output json | jq -r '.[]|select(.name=="obo-demo")|.id')
echo $SID
podman exec openshell-spiffe-demo-spire-server /opt/spire/bin/spire-server \
  entry create -socketPath /run/spire/server/private/api.sock \
  -parentID spiffe://openshell.local/openshell/spire-agent/demo \
  -spiffeID spiffe://openshell.local/openshell/sandbox/$SID \
  -selector docker:label:openshell.managed:true \
  -selector docker:label:openshell.ai/sandbox-id:$SID
```
> **Say:** and the sandbox gets its own cryptographic identity. That is what
> shows up in beat 3.

**Do beats 1 and 2 before beat 3.** The SPIFFE entry needs ~10 seconds to reach
the agent; beat 3 returns `token_grant_failed` if you go straight there.

---

## Beat 1: unlisted destinations are refused

**Say:** ordinary sandbox, ordinary policy. Watch an unauthorised host.

```shell
openshell sandbox exec --name obo-demo -- curl -sS http://example.com/
```
```
{"detail":"GET example.com:80/ not permitted by policy","error":"policy_denied"}
```
**Say:** nothing was blocklisted. `example.com` was simply never on the list.

```shell
openshell logs obo-demo -n 40 --source sandbox | grep DENIED | tail -1
```
**Say:** and the record names the calling program and the reason.

---

## Beat 2: an identity it cannot reach

**Say:** the sandbox has a cryptographic identity of its own.

```shell
podman exec openshell-spiffe-demo-spire-server /opt/spire/bin/spire-server \
  entry show -socketPath /run/spire/server/private/api.sock | grep -A1 sandbox
```

**Say:** used on its behalf. It cannot touch it:

```shell
openshell sandbox exec --name obo-demo -- ls /run/spire
```
```
ls: cannot access '/run/spire': No such file or directory
```
**Say:** the Workload API socket is not mounted. Nothing to steal.

---

## Beat 3: one request, two identities

**Say:** now a service that demands a real credential.

```shell
openshell sandbox exec --name obo-demo -- curl -sS http://alpha.default.svc.cluster.local:8080/
```
```
alpha called with path /:
  sub: demo-user
  aud: alpha, account
```
**Say:** it worked, and the service knows both the user it is for and the
workload that asked.

```shell
podman exec openshell-spiffe-demo-issuer \
  curl -s --unix-socket /tmp/debug.sock localhost/debug/last-token | jq '.tokens[0].claims|{sub,act}'
```
```json
{ "sub": "demo-user",
  "act": { "sub": ".../sandbox/<uuid>",
           "act": { "sub": ".../gateway/demo" } } }
```
**Say:** `sub` is the user. The `act` chain reads outward: the sandbox acted,
the gateway acted for it. Full attribution, no shared secret.

```shell
openshell sandbox exec --name obo-demo -- env | grep openshell:resolve
```
**Say:** and the agent never held any of it. Everything credential-shaped in
there is a placeholder only the egress proxy can resolve.

---

## Beat 4: same destination, different tool

**Say:** two tools on the same MCP server. I am granting the agent both,
explicitly.

```shell
openshell sandbox exec --name obo-demo -- claude --print --mcp-config "$MCP" \
  --strict-mcp-config --allowedTools='mcp__obo-demo__weather_lookup,mcp__obo-demo__database_query' \
  'Use weather_lookup for Warsaw, then database_query to run SELECT * FROM users. Report exactly what happened with each.'
```
```
Warsaw: 14°C, cloudy, wind 4 km/h NNW
database_query — Failed (Policy Denied)
```
**Say:** I allowed the agent both. The platform still refused one. Same host,
same port, same connection. The difference is the tool name.

`--allowedTools` is load-bearing: without it Claude Code's own permission
prompt blocks both calls before OpenShell ever sees them.

**Optional, skip if tight.** A refusal is not a dead end:

```bash
openshell sandbox exec --name obo-demo -- ls /etc/openshell/skills/
```

**Say:** the sandbox ships the agent a skill documenting `policy.local`, an API
inside the sandbox for proposing a narrow rule. Proposals land in a review
queue: the agent asks, a human still decides.

Do not promise more than this. The deny bodies here carry `policy_denied` and a
detail string, not the richer `next_steps` shape. That comes from the REST rules
inspector, and both denials in this demo are refused earlier, at the endpoint
gate.

---

## Beat 5: same destination, different program

**Say:** the policy also cares which program is calling.

```shell
openshell sandbox exec --name obo-demo -- curl -sS http://mcp.default.svc.cluster.local:8080/healthz
```
```
{"detail":"GET mcp.default.svc.cluster.local:8080/healthz not permitted by policy","error":"policy_denied"}
```
**Say:** the agent just reached that exact host and port. `curl` cannot.

```shell
openshell logs obo-demo -n 40 --source sandbox | grep DENIED | grep curl | tail -1
```
```
... [reason:binary '/usr/bin/curl' not allowed in policy 'mcp_tools']
```
**Say:** the refusal names the program. The caller was told only
`policy_denied` — the reason lives in the audit record, where the operator can
see it and the sandbox cannot.

---

## If something fails

Move to the next beat. They are independent and nothing unwinds.

Beat 4 without the agent (note the absolute path: a bare `python3` is a
uv interpreter the policy does not sanction):

```shell
openshell sandbox exec --name obo-demo -- /usr/bin/python3 -c \
  'import json,urllib.request as u;r=u.Request("http://mcp.default.svc.cluster.local:8080/",
   data=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"weather_lookup","arguments":{"city":"Warsaw"}}}).encode(),
   headers={"Content-Type":"application/json","MCP-Protocol-Version":"2025-11-25"});print(u.urlopen(r).read().decode())'
```

Environment wrong? `bash demo/teardown.sh && bash demo/bring-up.sh` is 40
seconds. If that fails twice, play the recording. Do not debug on stage.

---

## Short form

`bash demo/walkthrough.sh short` is the five-minute cut: six commands, no SPIRE
or SPIFFE machinery on screen. Use it when the clock is against you.

1. **Create the sandbox** — two providers attached
   > two credentials, neither of them for the agent
2. **`env | grep openshell:resolve`** — one placeholder, and the delegated
   credential is not even present
   > only the proxy can turn that into a token
3. **One agent call, both MCP tools pre-approved** — `weather_lookup` through,
   `database_query` refused
   > same server, same port, same connection. the difference is the tool
4. **`curl` to that same MCP host** — refused
   > the agent just reached it. curl cannot
5. **The audit record** — names `/usr/bin/curl` and the policy
   > the caller was told only `policy_denied`
6. **`curl` to the protected service** — succeeds, `sub: demo-user` plus the
   sandbox as `azp`
   > minted for this request, gone in five minutes

Dropped versus the full version: the `example.com` default-deny, the SPIRE entry
listing, `/run/spire`, and the `act` chain. The identity registration still
happens, quietly, inside the driver — which is what Kubernetes does for you
anyway.
