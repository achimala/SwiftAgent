# AgentKit iSH ARM64 Vendor Notes

This directory vendors `OpenMinis/ish-arm64` for the AgentKit iOS shell proof
of concept. The upstream project is GPLv3; keep the upstream license files in
this directory when redistributing.

Local AgentKit changes currently include:

- a host-safe exit hook so guest `/bin/sh -c ...` exits do not terminate the
  embedding iOS process
- explicit stdio FD plumbing for an embedded pipe-backed shell session
- a small C session API in `tools/agentkit_ish_session.*`
- a `-b /guest=/host` bind-mount option used to expose the AgentKit workspace
  at `/workspace`
- Meson targets for local smoke tests and static iOS packaging

The intended embedded shape is a single long-lived guest shell session. One
shot guest process invocation is not currently reentrant in a single host
process because iSH kernel state is global.
