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

1. **IAM user** with an access key, and a policy scoped to this record
   only — not the whole zone:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "route53:ChangeResourceRecordSets",
         "Resource": "arn:aws:route53:::hostedzone/<ZONE_ID>",
         "Condition": {
           "ForAllValues:StringEquals": {
             "route53:ChangeResourceRecordSetsNormalizedRecordNames": ["ntfy.chrisscotmartin.com"],
             "route53:ChangeResourceRecordSetsRecordTypes": ["A"]
           }
         }
       },
       {
         "Effect": "Allow",
         "Action": ["route53:ListResourceRecordSets", "route53:GetHostedZone"],
         "Resource": "arn:aws:route53:::hostedzone/<ZONE_ID>"
       }
     ]
   }
   ```

2. **Vault** — store the credentials at `kv/ddns/config`:

   ```
   vault kv put kv/ddns/config \
     aws_access_key_id=AKIA... \
     aws_secret_access_key=... \
     hosted_zone_id=Z...
   ```

3. **Vault role** — already declared in `bootstrap/vault-policies.sh`;
   re-run it to create the `ddns` policy and Kubernetes auth role.

Until steps 1–2 are done the ExternalSecret stays unsynced and the
CronJob's pods will fail to start. That's the intended failure mode:
no credential, no writes.

## Verifying

```
kubectl -n ddns create job --from=cronjob/ddns ddns-manual
kubectl -n ddns logs job/ddns-manual
```

Expect `in sync: ntfy.chrisscotmartin.com -> <ip>` when nothing has moved.
