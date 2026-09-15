# `openshell sandbox connect` never attaches; `sandbox exec --tty -- bash -i` works

**Status:** draft, not yet filed. Target: NVIDIA/OpenShell.

**Confidence:** the non-TTY hang is reproducible and clear cut. The interactive
behaviour was only ever driven through a synthetic PTY, so the "produces no
output" part may be an artefact of that harness rather than a real defect. Worth
one manual attempt in a normal terminal before filing.

---

## Summary

`openshell sandbox connect <name>` never produced an attached shell in any
attempt. From a non-TTY shell it hangs indefinitely. Driven through a PTY it
accepts input, echoes it, and returns nothing.

`openshell sandbox exec --name <name> --tty -- bash -i` gives a working
interactive shell against the same sandbox, in the same environment, which is
what makes this look like a `connect` problem rather than an environment one.

## Environment

| | |
|---|---|
| OpenShell CLI | 0.0.116 |
| Gateway image | `ghcr.io/nvidia/openshell/gateway:d1155aa7` (v0.0.116) |
| Compute driver | podman |
| Host | macOS, Apple Silicon, `podman machine` (applehv) |
| VM | Fedora CoreOS 44.20260607.3.1, kernel 7.0.11 aarch64 |
| Podman | 6.0.0 in the VM, 6.1.1 on the host |

All commands run inside the VM over `podman machine ssh`, with
`OPENSHELL_GATEWAY_ENDPOINT` set. The sandbox was created with
`--keep --detach --no-tty -- sleep infinity` and is `Ready`.

## Steps to reproduce

```shell
openshell sandbox create --name obo-demo --keep --detach --no-tty -- sleep infinity
openshell sandbox list          # obo-demo ... Ready

openshell sandbox connect obo-demo
```

## Actual

**From a non-TTY shell** (stdout a pipe): hangs with no output. Left running, it
eventually drops the connection rather than reporting anything useful:

```
Connection to sandbox closed by remote host.
client_loop: send disconnect: Broken pipe
```

**Through a PTY**: the command echoes, subsequent input echoes, nothing is
rendered back. Detaching with Ctrl-P Ctrl-Q returns to the parent shell. The
captured session shows only:

```
(demo) $ openshell sandbox connect obo-demo
hostname
^P
```

A `Usage: openshell [OPTIONS] [COMMAND]` error was also observed once from an
interactive shell, but could not be reproduced and is not characterised here.

## Expected

An attached interactive shell in the sandbox, per `--help`:

> Connect to a sandbox. When no name is given, reconnects to the last-used
> sandbox. Press Ctrl-P Ctrl-Q to disconnect without terminating the main
> process.

## Workaround

```shell
openshell sandbox exec --name obo-demo --tty -- bash -i
```

Works first time, every time:

```
sandbox@sandbox-obo-demo:~$ hostname
sandbox-obo-demo
sandbox@sandbox-obo-demo:~$ curl -sS http://mcp.default.svc.cluster.local:8080/healthz
{"detail":"GET mcp...:8080/healthz not permitted by policy","error":"policy_denied"}
sandbox@sandbox-obo-demo:~$ exit
```

Policy enforcement is unaffected by the interactive shell in the process
ancestry: the binary rule still refuses `curl` on a host the agent can reach.

## Notes for whoever picks this up

- The sandbox's main process is `sleep infinity`. If `connect` attaches to the
  canonical main process rather than starting a new one, attaching to a
  non-interactive `sleep` would look exactly like this. That is a guess, not a
  finding.
- Related and confirmed in the same session: `sandbox create` without
  `--detach` also never returns when stdout is a terminal, because it attaches
  to that same `sleep infinity`. `--no-tty` does not prevent it; the two flags
  control different things. If `connect` shares that attach path, the two are
  probably the same bug.
