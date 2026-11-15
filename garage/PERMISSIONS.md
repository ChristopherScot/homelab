# Who may touch which bucket

Garage's permission model is small, and that is the point: there are
keys, there are buckets, and a key is granted Read, Write or Owner on a
bucket. Nothing else. No IAM policies, no prefix rules, no conditions,
no temporary credentials. If two things need different access they need
different buckets or different keys.

Each key is an identity. The rule here is **one key per consumer, one
bucket per dataset, grants connect them.** A key is never shared between
two services, because a shared key cannot be revoked for one of them and
Garage's logs cannot tell them apart.

## The four layers a credential passes through

```
garage key  ──►  Vault kv path  ──►  Vault policy  ──►  ExternalSecret  ──►  pod env
(identity)       (the secret)        (who may read      (projects it         (envFrom)
                                      that path)         into a namespace)
```

| Layer | Declared in | Who runs it |
|---|---|---|
| key, bucket, grant | `bootstrap/garage-init.sh` | a human, once per cluster |
| secret value | `vault kv put kv/garage/<key>` | a human, once per key |
| which role may read it | `bootstrap/vault-policies.sh` | a human, re-runnable |
| projection into a namespace | `<app>/secrets.yaml` ExternalSecret | Argo |
| use | `envFrom: secretRef` on the pod | Argo |

The first three are not Kubernetes objects, so Argo does not reconcile
them and no diff shows them. That is why they are scripts in git rather
than commands in a terminal: re-running the script is how you reconcile.

The Vault path is named after the key's purpose, not the consumer:
`kv/garage/s3-reference` is "the read key for reference material",
which happens to be used by claude-pods today.

## Today

| Key | Grant | Vault path | Projected into | Used by |
|---|---|---|---|---|
| `claude-worker` | R on `claude-reference` | `kv/garage/s3-reference` | `claude-pods/garage-s3-reference` | worker pods at boot |
| `claude-seed` | RW on `claude-reference` | `kv/garage/s3-seed` | `claude-pods/garage-s3-seed` | the seed Job, run by hand |

The split is the house pattern: whatever runs unattended gets Read, and
the Write key is only ever mounted by the one Job a human starts. A
buggy or compromised worker cannot overwrite the books every other
worker boots from.

## Walkthrough: a new service that needs its own bucket

Say `paperless` wants to archive exports to S3.

1. **Bucket and key, in Garage.** From any garage pod:
   ```sh
   garage bucket create paperless-archive
   garage key create paperless
   garage bucket allow --read --write paperless-archive --key paperless
   garage key info paperless --show-secret     # once, for step 2
   ```
   Then add the same to `bootstrap/garage-init.sh` so the next rebuild
   recreates them: a bucket stanza like the one for `claude-reference`,
   an `ensure_key paperless paperless/garage-s3-paperless` line naming
   the Secret from step 4, so a rebuilt cluster imports the credential
   paperless already holds rather than minting one and breaking it, and
   the `bucket allow` line, because a grant belongs to a key and a
   rebuilt key has none.

2. **Secret, in Vault.**
   ```sh
   vault kv put kv/garage/s3-paperless access-key-id=GK... secret-access-key=...
   ```

3. **Permission to read it, in Vault.** In `bootstrap/vault-policies.sh`,
   the paperless policy gains one line:
   ```
   path "kv/data/garage/s3-paperless" { capabilities = ["read"] }
   ```
   Re-run the script. A policy names exact paths, never `garage/*`: the
   claude-pods policy must not be able to read paperless's key, and
   `claude-pods/tests/garage-vault.sh` checks that it cannot.

4. **Projection, in git.** In `paperless/secrets.yaml`, an ExternalSecret
   through paperless's existing SecretStore, with the same four fields
   every S3 client needs:
   ```yaml
   target:
     template:
       data:
         AWS_ACCESS_KEY_ID: "{{ .access_key_id }}"
         AWS_SECRET_ACCESS_KEY: "{{ .secret_access_key }}"
         AWS_DEFAULT_REGION: "garage"
         AWS_ENDPOINT_URL: "http://garage.garage.svc.cluster.local:3900"
   data:
     - secretKey: access_key_id
       remoteRef: { key: garage/s3-paperless, property: access-key-id }
     - secretKey: secret_access_key
       remoteRef: { key: garage/s3-paperless, property: secret-access-key }
   ```
   The region is not decoration: garage.toml sets `s3_region = "garage"`
   and rejects requests naming any other.

5. **Use.** `envFrom: [{secretRef: {name: garage-s3-paperless}}]` on the
   pod. Any S3 client honours those four variables.

Verify the ExternalSecret reports `SecretSynced`; a Ready SecretStore
alone does not prove the path is readable, that is what step 3 is for.

## Walkthrough: two services share a bucket

Say `homepage` wants to show thumbnails of paperless's exports.

Two keys, one bucket. `homepage` gets its own key with Read:

```sh
garage key create homepage
garage bucket allow --read paperless-archive --key homepage
```

then its own Vault path, policy line and ExternalSecret exactly as
above. What is shared is the bucket; the identities stay separate, so
homepage can be revoked (`garage bucket deny --read ... --key homepage`)
without paperless noticing, and a write can only have come from the one
key that could write.

The tempting shortcut - grant the homepage Vault role read on
`kv/garage/s3-paperless` so it uses paperless's key - is the thing to
refuse. It is one line instead of four, and it means two services with
one revocation lever and one audit trail.

## Walkthrough: one service, two buckets

Same key, two grants: `garage bucket allow --read other-bucket --key paperless`.
A key is an identity, not a per-bucket token; it may hold any number of
grants. Nothing in Vault changes.

## What Garage cannot express

- **Prefix-level access.** A key sees all of a bucket or none of it. If
  workers must not read each other's output, they need separate buckets,
  not separate prefixes.
- **Bucket policies, conditions, temporary credentials.** None. The
  Kubernetes namespace is the trust boundary: anyone who can read Secrets
  in `claude-pods` holds `claude-worker`. Keep the Write key out of
  namespaces where unattended things run.
- **Owner** lets a key change bucket settings (website, quotas). No pod
  needs it; the garage CLI from inside a pod is the admin path.

Two things worth knowing that are not permissions: a bucket can have a
quota (`garage bucket set-quotas --max-size 5GiB paperless-archive`),
which is how a shared store stays shared; and the admin port 3903 has
no token, so `/health` and `/metrics` answer anyone in the cluster while
every endpoint that could change anything returns 403 - checked, not
assumed.

## Rotating a key

Create the replacement **under the same name**, grant it, update Vault,
let it propagate, delete the old one by id:

```sh
garage key create paperless                 # names are not unique; this is a second key
garage key info paperless                   # ambiguous now - use the ids below
garage bucket allow --read --write paperless-archive --key <new id>
vault kv put kv/garage/s3-paperless access-key-id=<new> secret-access-key=<new>
# ExternalSecrets refresh every minute; pods with reloader's annotation restart
garage key delete <old id> --yes
```

The name stays because `garage-init.sh` finds a key by name and then
checks it against the Secret: a key called `paperless-2` would leave the
committed `ensure_key paperless ...` line pointing at nothing, and the
next rebuild would mint a stranger. While both keys exist the name is
ambiguous, so do not run the init script mid-rotation. A grant belongs
to a key, so the new one needs its own; Vault keeps the path, so nothing
in git changes.
