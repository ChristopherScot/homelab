# Authelia

Forward-auth in front of every internal app. Login at `auth.lab`. Sessions in
Redis, persistent state (2FA enrollments, regulation) in SQLite on a
`synology-iscsi` PVC.

## Adding auth in front of a new ingress

Set these annotations on the ingress in the *consuming* namespace:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://authelia.authelia.svc.cluster.local/api/verify"
    nginx.ingress.kubernetes.io/auth-signin: "http://auth.lab?rd=$target_url"
    nginx.ingress.kubernetes.io/auth-response-headers: "Remote-User,Remote-Name,Remote-Email,Remote-Groups"
```

The host on the ingress (e.g. `sonarr.lab`) must also have a matching rule in
`authelia/configmap.yaml` under `access_control.rules` — otherwise the default
`deny` policy applies.

## Users

User database lives in Vault at `kv/authelia/users`. To rotate a password:

```bash
kubectl run h --rm -i --restart=Never --image=authelia/authelia:4.38 -- \
  authelia crypto hash generate argon2 --password '<NEW>'
# then update the yaml field in kv/authelia/users with the new hash
```

The ExternalSecret refreshes hourly; force a refresh with
`kubectl annotate externalsecret -n authelia authelia-users force-sync=$(date +%s) --overwrite`.

## 2FA

No SMTP, so when a user enrolls 2FA, Authelia writes the enrollment URL to
`/config/notification.txt` inside the pod. Recover it with:

```bash
kubectl exec -n authelia deploy/authelia -- cat /config/notification.txt
```

The URL contains the `otpauth://` line — paste into a TOTP app (1Password,
Aegis, Google Authenticator).
