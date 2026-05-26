# Multi-user ephemeral Claude Code envs — scoping

Goal: turn the homelab `claude-pods` setup into a reusable system where any
team member runs a thin client (`rclaude <url>`) to drop into their own
Claude Code dev env, reachable **only over the Tailscale VPN**. Must replicate
at the company (GCP, **no Kubernetes**) with minimal change.

Status: SCOPING ONLY — nothing here is built. The homelab StatefulSet version
(in this dir) is the reference implementation of the portable core.

---

## Portable core (transfers everywhere — the actual value)

These are deployment-agnostic and already exist in this repo:

- **The image** (`claude-pods/Dockerfile` → `ghcr.io/christopherscot/claude-pod`):
  Claude CLI + git/gh/kubectl/helm/yq + Go/TS/OpenTofu + LazyVim (Go/TS/HCL
  LSP+DAP) + zsh/oh-my-zsh/starship/zoxide/eza/fzf + tmux (resurrect) +
  lazygit/delta/direnv. UTF-8 locale. **This is the crown jewel — it's just a
  container, runs anywhere.**
- **Baked non-secret UX flags** (`~/.claude.json`: `/workspace` trust,
  `remoteDialogSeen`, onboarding) so fresh envs skip prompts the auto-start
  `claude remote-control` server can't answer.
- **Conventions:**
  - Persistent `$HOME` (on fast storage) → Claude login + shell/nvim state
    survive restarts. Login is per-user, NEVER baked into the image.
  - Persistent `/workspace` (can be slower/bulk storage) → repos + changes.
  - `claude remote-control` auto-starts in tmux (restart-loop) → reachable
    from claude.ai/code + mobile, survives restarts.
  - Per-env repos via env var(s); first repo = "primary" for `rclaude`.
  - GitHub token from a secret store (never in the image), mounted as
    `~/.git-credentials`. Per-user token = per-user push identity/scope.

## NOT portable (homelab-specific scaffolding — replaced per target)

Longhorn storage tiers/SC, StatefulSet, Argo/GitOps, Vault/ExternalSecrets,
MetalLB, ghcr. Each maps to a target-specific equivalent (below).

---

## Deployment target A — homelab (Kubernetes) — REFERENCE, mostly built

- StatefulSet (2 replicas), per-pod PVCs ($HOME on SSD SC, /workspace on HDD SC)
- Token via Vault + ExternalSecret; image from ghcr (pull secret)
- VPN exposure: **NOT yet done** — needs Tailscale k8s operator so each pod is
  a tailnet node with Tailscale SSH (deferred). Until then, access is
  `ssh homelab → kubectl exec` (admin-only, doesn't generalize to teammates).

## Deployment target B — company (GCP, no k8s) — TO BUILD

Decisions made: **one shared GCE VM, a container per user.** Company already
has **Terraform + Tailscale** (reuse, not net-new).

| Concern            | GCP implementation |
|--------------------|--------------------|
| Compute            | One GCE VM running Docker; one container per user |
| Per-user $HOME     | Per-user persistent disk *or* a docker volume on an attached PD |
| /workspace         | docker volume (or a path on the PD) |
| GitHub token       | **GCP Secret Manager** (per-user secret), injected as env/file |
| Image registry     | **Artifact Registry** (push the same Dockerfile build there) |
| Provisioning       | **Terraform module**: VM + PD + firewall + Secret Manager + (Tailscale auth key) |
| VPN-only (network-enforced) | VM has **no public IP** + firewall denies all non-tailnet ingress + Tailscale on the VM. Off-tailnet = literally unroutable. **Simpler than the k8s operator.** |
| Per-user container lifecycle | a small launcher: `docker run` per user with their volume+secret+name, or systemd template / docker-compose. (This is the one bit of "mini-orchestration" to hand-roll.) |

Cost lever: stop the VM when no one's using it; PDs persist.

### Per-user persistence + separation (GCP shared VM)

Threat model (confirmed): prevent an agent in user A's env from touching
user B's files — a **blast-radius/accident** concern between *trusted* users,
NOT hostile container-escape. So no gVisor/Kata/userns/per-user-VM needed;
bind-mount isolation is sufficient and is the right-sized answer.

Layout — one PD, per-user subtree:
```
/srv/claude-envs/
  <user>/
    home/        -> bind-mounted to /home/node   (Claude login, shell, nvim)
    workspace/   -> bind-mounted to /workspace    (repos + changes)
```
Each container mounts ONLY that user's subtree:
```
docker run --name claude-<user> \
  -v /srv/claude-envs/<user>/home:/home/node \
  -v /srv/claude-envs/<user>/workspace:/workspace \
  --secret <user-github-token> ...  ghcr.../claude-pod
```

- **Separation** = the bind-mount itself: B's dir is never mounted into A's
  container, so A's agent has no path to reach it. Belt-and-suspenders:
  `chmod 0700` + per-user owner on each subtree (host-side tidiness).
- **Persistence** = the subdirs live on the VM's persistent disk: login +
  repos survive container restarts; GCP PD durability + snapshots = backup.
- Same `$HOME`-on-fast, `/workspace`-bulk split as homelab if the PD is
  tiered; otherwise one PD is fine (interactive lag was a Longhorn-HDD
  artifact, not a general issue — a normal GCP PD/SSD is fast).
- NOT needed for this threat model: gVisor/Kata, userns-remap, per-user VMs.
  (Revisit only if the threat model ever becomes hostile/untrusted users.)

---

## The `rclaude` thin client (works against BOTH targets)

The binary doesn't care if the target is a k8s pod or a GCE container — both
are containers on the tailnet with Tailscale SSH. It:

1. Takes a URL/name → resolves to a **tailnet hostname**.
2. (Friendly pre-check: `tailscale status`; real gate is the network.)
3. `tailscale ssh <host>` → runs the in-image `rclaude-layout` (nvim + claude +
   shell tmux layout).

VPN-only is **network-enforced**, not a client check: off-tailnet the host
doesn't resolve/route, so there's nothing to connect to (spoof-proof).

Form: a Go single-binary (cross-platform, `brew`/release distributable) is the
end state; a shell wrapper around `tailscale ssh` is fine to prototype.

---

## Milestone plan

1. **M1 — prove the model in homelab:** Tailscale k8s operator + expose the 2
   existing pods as tailnet nodes w/ Tailscale SSH + ACLs; thin `rclaude
   <tailnet-host>` attaches over the tailnet (network-enforced). Validates the
   whole connection/auth/VPN model end-to-end.
2. **M2 — parameterize:** turn the StatefulSet into a per-user template
   (Helm chart: name, repos, token path, tailnet host) + per-user Vault token.
3. **M3 — GCP target:** Terraform module (shared VM + Docker + per-user
   container launcher + Secret Manager + Artifact Registry image + Tailscale).
   Reuses the SAME image + conventions.
4. **M4 — the binary:** Go `rclaude`, distributable, targets either backend.

---

## Open questions (resolve before building)

- **URL scheme:** just the tailnet host (`rclaude claude-app`)? Or encode
  repo/layout too?
- **Env granularity:** one env per person, or per-person-per-project?
  (Affects naming + Tailscale ACLs.)
- **Tailscale ACLs:** model for "user X reaches only their env"; how ACLs are
  updated as people onboard/offboard. Tag-based (`tag:claude-env`) + per-user
  grants is the likely shape.
- **Auth to Claude:** each user does interactive `/login` once per env
  (persists on their $HOME volume). Confirm acceptable for the company (uses
  each person's own claude.ai subscription/seat).
- **Idle/cost:** k8s pods ~free idle; GCP VM should auto-stop when idle
  (PDs persist). Who/what stops it?
- **Secret hygiene:** per-user GitHub tokens should be **fine-grained PATs**
  scoped to the repos that user needs — not broad personal tokens (the homelab
  currently uses a shared broad token; do NOT replicate that at the company).
