# ddns

Keeps the Route 53 `A` record for `ntfy.chrisscotmartin.com` pointed at the
house's current WAN address.

## Why

Comcast rotates the WAN IP without notice. On 2026-09-14 DNS still read
`76.153.223.132` while the house had moved to `76.110.226.187`, so every
from-outside path to ntfy failed with a TCP timeout. Phone notifications
stopped and `toclip` silently stopped working — nothing surfaced the
breakage, because in-cluster alerting uses
`ntfy.ntfy.svc.cluster.local` and kept working fine.

`ntfy.chrisscotmartin.com` is the only hostname published to the WAN
(everything else is `*.home.chrisscotmartin.com` → `192.168.50.225`,
LAN-only), so this one record is the entire public surface.

## Safety properties

The CronJob runs every 5 minutes and only writes DNS when **all** of:

- both `api.ipify.org` and `ifconfig.me` return an address,
- both parse as an IPv4 dotted quad,
- both **agree**, and
- the agreed address differs from what Route 53 currently serves.

Any other outcome logs and exits 0 without touching DNS. The point is that
a flaky or hijacked echo service can't publish a bogus address — a wrong
answer here would black-hole the only public hostname.

The current value is read from the Route 53 API rather than a resolver, so
a stale cached answer can't trigger a pointless change.

On a real change it publishes to `homelab-warning` so the change is
visible rather than silent.

## One-time setup (manual, outside GitOps)

No new IAM user is needed. This reuses the existing cert-manager Route 53
credential (IAM user `cert-manager-route53`, inline policy
`route53-dns01-chrisscotmartin`), whose policy already allows exactly
`ChangeResourceRecordSets` + `ListResourceRecordSets` on the
`chrisscotmartin.com` zone — everything this job does and nothing more.

That policy is scoped to the zone rather than to the single `ntfy` A
record, so it is marginally broader than strictly required. Accepted
deliberately: one credential to rotate beats two, and it is already
homelab-specific and zone-limited.

The only setup step is making sure the Vault item carries **both** halves
of the credential. Historically only the secret was stored there, with the
key ID inlined in `cert-manager-config/clusterissuer.yaml`. Check:

```
kubectl exec -n default vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_TOKEN" vault kv get kv/cert-manager/route53
```

If there is no `access_key_id` property, add it without disturbing the
existing secret (`patch`, not `put` — `put` replaces the whole item):

```
kubectl exec -n default vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_TOKEN" vault kv patch kv/cert-manager/route53 \
  access_key_id=<the AKIA... value from clusterissuer.yaml>
```

Then create the Vault policy + Kubernetes auth role:

```
kubectl -n default port-forward svc/vault 8200:8200 &
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root> ./bootstrap/vault-policies.sh
```

Until the ExternalSecret can resolve both properties it stays unsynced and
the CronJob's pods won't start. That is the intended failure mode: no
credential, no writes.

### Note on the key ID in git

`cert-manager-config/clusterissuer.yaml` has the AWS access key ID inline
(cert-manager's `ClusterIssuer` schema takes it as a plain field, with only
the secret behind a `SecretRef`). The secret half has never been in git.
A key ID is an identifier rather than a credential, but this repo is
public, so this app keeps both halves in Vault instead. Tidying the
cert-manager side the same way is a reasonable follow-up; note that git
history would still carry the old value, so genuinely removing it means
rotating the key.

## Verifying

```
kubectl -n ddns create job --from=cronjob/ddns ddns-manual
kubectl -n ddns logs job/ddns-manual
```

Expect `in sync: ntfy.chrisscotmartin.com -> <ip>` when nothing has moved.
