# Codex pod

`codex-session-0` runs in `codex-pods`, with its own home and workspace PVCs,
service accounts, SecretStore, and secrets. It uses the existing tooling image
and GitHub account in Vault, with a pinned
Codex CLI installed by an init container. No new image build or CI job is needed.
The `codex-pods` Argo CD Application owns its deployment.

On startup it checks ChatGPT authentication, verifies GitHub repository access,
clones `ChristopherScot/homelab`, and requests the literal `CODEX_POD_OK` outside
the repository. Readiness requires that real model response. It then idles:
there is no schedule, autonomous repository task, PR creation, or merge behavior.
No Kubernetes service account token is mounted.

## Authentication

The Vault KV v2 path `kv/codex-pods/auth`, property `auth_json`, holds the
initial ChatGPT login cache. `codex-auth-seed` syncs it through the existing
`vault-codex-pods` SecretStore. Credentials never belong in this repository.
`bootstrap/codex-vault.sh` declares the namespace-scoped Vault Kubernetes role
and its read-only policy. It is also called by `bootstrap/vault-policies.sh`.

The seed must come from a **separate OAuth login reserved for this pod**, not a
copy of a laptop login that remains in use. Two machines refreshing the same
credential bundle can invalidate each other's authentication. Create the pod's
login with an isolated `CODEX_HOME` and file-based credential storage, complete
its OAuth authorization, and seed that cache into Vault. Stop using that
isolated login locally after transferring it to the pod. Browser sign-in or
human verification may be required for that initial authorization.

The entrypoint copies the seed only if `$CODEX_HOME/auth.json` is absent. Codex
refreshes that writable file on the home PVC, which must survive restarts.
The original Vault seed does not track refreshed tokens and must not overwrite
the PVC copy. If the home PVC is lost, seed Vault with a current login before
recreating the pod. A revoked or expired login may require authenticating again;
this does not bypass ChatGPT plan limits or account policies.

Official documentation: [headless authentication and login caching](https://learn.chatgpt.com/docs/auth?surface=cli).
See also [one refresh stream per credential bundle](https://learn.chatgpt.com/docs/auth/ci-cd-auth).

## Use and inspect

Deployment changes go through a PR, merge, and Argo CD reconciliation.
Read-only checks:

```sh
kubectl get pods -n codex-pods -l app=codex-session
kubectl logs -n codex-pods codex-session-0 -c codex
```

Once ready, Codex is available inside the pod at `/opt/codex/node_modules/.bin/codex`.
The repository is `/workspace/homelab`; the writable login cache and session
state are under `/home/node/.codex`. Future task dispatch is intentionally
left unconfigured until its behavior is specified.
