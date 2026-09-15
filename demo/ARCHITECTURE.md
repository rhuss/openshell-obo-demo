# How the demo is put together

What each piece is, who issues which identity, and where the token exchange
actually happens. Read this once before rehearsing; the answers to the two
questions an audience always asks are in here.

## The problem

An agent needs to call a service on a user's behalf. The obvious approach is to
give the agent the user's credential, which means the agent holds something it
can use for anything, for as long as it lives, and the service cannot tell
whether the user or the agent made a request.

The demo replaces that with a credential minted per request, scoped to one
destination, naming both the user and the workload that asked, which the agent
never holds in usable form.

## Two kinds of identity, two different issuers

This is the distinction worth being clear about on stage, because "identity"
means two different things here.

**Who the user is** comes from the token issuer. In the demo that is
`demo/issuer/token-issuer.js`, a stand-in for whatever IdP you actually run.
`GET /demo-subject-token` mints a JWT with `sub: demo-user` and a two hour
lifetime. There is no login because there is no user directory. In production
this is Keycloak, Okta, Entra, whatever, and nothing downstream changes.

**What a workload is** comes from SPIRE. The gateway and the sandbox each get a
SPIFFE identity, issued by the SPIRE server through the SPIRE agent, which
attests them by inspecting the container they run in:

```
spiffe://openshell.local/openshell/gateway/demo      the gateway
spiffe://openshell.local/openshell/sandbox/<uuid>    this sandbox, specifically
```

Attestation is on container labels: `docker:label:openshell.spiffe-demo:gateway`
for the gateway, and the sandbox's own `openshell.ai/sandbox-id` label. Nothing
is shared, nothing is configured with a secret, and an identity cannot be moved
to another container.

These identities are short-lived (300s JWT-SVIDs) and are never used *as*
credentials for the protected service. They are used to prove who is asking for
one.

## The components

```
                        ┌──────────────────────────────┐
   SPIRE server ────────│ issues SVIDs via the agent   │
   + OIDC provider      │ JWKS at spire-oidc:8080/keys │
        │               └──────────────────────────────┘
        │ attests
        ├────────────────► gateway         (has a SPIFFE identity)
        └────────────────► sandbox         (has a SPIFFE identity)

   token issuer   :8097  the demo's IdP, and the RFC 8693 exchange endpoint
   alpha          :8099  the protected service; validates the final token
   mcp            :8100  MCP server, two tools: weather_lookup, database_query
   gateway        :8101  holds credentials, enforces policy, routes inference
   sandbox               the agent's workspace; supervisor + egress proxy
```

Nine components reach ready. The SPIRE trio and the OIDC provider exist so that
the issuer can *verify* a JWT-SVID without talking to SPIRE: it fetches the
public keys from the OIDC discovery provider and checks signatures itself.

## Where the token exchange happens

In two phases, in two different places. This surprises people, and it is the
reason the final token can name both identities.

### Phase one: gateway → issuer

Triggered when the sandbox first needs the credential. The **gateway** calls the
issuer's `/token` endpoint with:

- the stored user subject token, as the subject of the exchange
- its own JWT-SVID as the client assertion
  (`client_assertion_type: …jwt-spiffe`, not a client secret)
- an audience of **the sandbox's SPIFFE ID**

The issuer verifies the gateway's SVID: right signature, right issuer, right
audience, and a subject starting with the gateway prefix. It returns an
**intermediate** token: `sub: demo-user`, `aud: <sandbox SPIFFE ID>`,
`act: {sub: <gateway>}`, 300 seconds.

That token is useless to anyone but that specific sandbox, because its audience
names it.

### Phase two: sandbox supervisor → issuer

Happens inside the sandbox, in the supervisor's egress proxy, at the moment a
request goes out. The **supervisor** calls the same `/token` endpoint with:

- the intermediate token as the subject
- its own JWT-SVID as the client assertion
- the audience for the destination being called (`alpha`)

The issuer verifies the supervisor's SVID, then checks that the intermediate
token's audience matches that supervisor's SPIFFE ID. Only then does it mint
the **final** token:

```json
{
  "sub": "demo-user",
  "aud": ["alpha", "account"],
  "scope": "alpha profile email",
  "act": {
    "sub": "spiffe://openshell.local/openshell/sandbox/<uuid>",
    "act": { "sub": "spiffe://openshell.local/openshell/gateway/demo" }
  }
}
```

The `act` chain is RFC 8693's most-recent-actor-outermost convention: the
sandbox acted, and the gateway acted before it. The protected service reads
`sub` to know the user and the chain to know what handled the request.

## What the agent actually holds

Nothing usable. The sandbox's environment contains
`openshell:resolve:env:…_ACCESS_TOKEN`, a placeholder. Only the egress proxy can
resolve it, and resolving it is what triggers the grant above. Inside the
sandbox it is a string.

The same trick covers inference. The agent talks to `https://inference.local`
with `ANTHROPIC_API_KEY=unused`; the gateway terminates that, discards the
placeholder, and injects a real one-hour GCP token minted from refresh material
the sandbox has never seen.

So there are three credentials in play and the agent holds none of them: the
user's subject token (gateway only), the GCP refresh material (gateway only),
and the per-request access token (materialised at the proxy boundary).

## What the policy does on top

Identity answers *who*. The policy answers *what is allowed*, and it is checked
per connection against both the destination and the calling binary:

- an unlisted destination is refused (beat 1)
- a listed destination reached by an unsanctioned binary is refused (beat 5)
- a permitted MCP endpoint with a non-permitted tool is refused (beat 4)

The refused caller is told only `policy_denied`. Which tool, which binary, and
which policy refused all appear in the audit record instead, where the operator
can see them and the sandbox cannot.

## What would be different in production

- The issuer is your real IdP. The subject token comes from a login.
- SPIRE attests on Kubernetes workload selectors rather than container labels.
- The `*.default.svc.cluster.local` names become real Kubernetes services
  instead of Podman network aliases. The policy does not change, which is why
  the demo uses that shape.
- The protected service is your service, validating the same claims.

The exchange, the act chain, the placeholder and the policy model are the same.
