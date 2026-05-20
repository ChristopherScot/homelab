# Paperless email ingestion via SES inbound → S3 → poller

## STATUS (2026-05-20)
AWS side DONE via `aws --profile personal` (acct 359062245689, us-east-1):
- S3 bucket `cscot-paperless-inbound` (public-access blocked, 14d lifecycle,
  SES PutObject bucket policy)
- Route53: DKIM CNAMEs + MX `docs.chrisscotmartin.com → inbound-smtp...`
  (apex ImprovMX forwarding left untouched)
- SES receipt rule set `paperless-inbound` (ACTIVE), rule `docs-to-s3`
  delivers `*@docs.chrisscotmartin.com` → s3://cscot-paperless-inbound/inbound/
- IAM user `paperless-s3-inbound` (bucket-scoped get/list/delete)
- Vault `kv/paperless/s3-inbound`: access_key_id, secret_access_key,
  bucket, region, prefix

REMAINING (cluster side, GitOps in paperless/):
- ExternalSecret `paperless-s3-inbound` from kv/paperless/s3-inbound
- Paperless API token (create in UI → Vault kv/paperless/config api_token)
- CronJob `paperless-mail-ingest` poller (see below)
- Vanessa logs into Paperless once (creates her user) before her
  owner-routing resolves
- Verify DNS propagated + send a test mail to chris@docs.chrisscotmartin.com

Design locked: per-user addresses `<user>@docs.chrisscotmartin.com`, poller
sets Paperless owner by recipient (chris/vanessa, default chris). Per-user
addresses are routing convenience; privacy comes from Paperless ownership.

---


Goal: email a document to `docs+chris@chrisscotmartin.com` /
`docs+vanessa@chrisscotmartin.com` and have it land in Paperless owned by
the right person — without running a mail server or using Gmail.

## Why this shape
- Already sending via SES (`email-smtp.us-east-1.amazonaws.com`, domain
  `chrisscotmartin.com` verified, SMTP creds in Vault `kv/ses/smtp`).
- SES can RECEIVE too: MX → SES inbound → receipt rule → write raw email
  to S3. Avoids self-hosted SMTP (port 25 / PTR / deliverability hell).
- Paperless ingests via IMAP, not S3, so we bridge with a small in-cluster
  poller that reads S3 and POSTs to the Paperless API (which lets us set
  the document owner per upload → routes by recipient address).

## AWS side (MANUAL — no Terraform/IaC in this repo; SES was set up by hand)
Region: us-east-1 (matches existing SES).
1. **MX record** for the receiving domain. Decide: receive on the apex
   `chrisscotmartin.com` (conflicts if you ever host real mail there) or a
   subdomain like `docs.chrisscotmartin.com` (cleaner, isolated).
   MX → `inbound-smtp.us-east-1.amazonaws.com` (priority 10).
2. **Verify the receiving domain/subdomain** in SES (if subdomain).
3. **S3 bucket** e.g. `cscot-paperless-inbound`, lifecycle rule to expire
   objects after N days (the poller deletes processed ones anyway).
4. **SES receipt rule set** + rule: recipients `docs@...` (catches
   docs+chris, docs+vanessa via subaddressing), action = **S3 deliver** to
   the bucket (optionally SNS notify, but polling is simpler).
5. **IAM user/policy** for the poller: `s3:ListBucket` + `s3:GetObject` +
   `s3:DeleteObject` on that bucket only. Store its access key in Vault at
   `kv/paperless/s3-inbound` (access_key_id, secret_access_key, bucket,
   region).

## Cluster side (GitOps, in paperless/)
6. **Paperless API token**: create a token for an ingestion service user
   (or reuse admin) in Paperless UI → store in Vault `kv/paperless/config`
   as `api_token`. Add to the paperless ExternalSecret.
7. **ExternalSecret** `paperless-s3-inbound` pulling the IAM creds (extend
   the paperless Vault policy if needed — it already reads kv/paperless/*).
8. **CronJob** `paperless-mail-ingest` (every ~5 min):
   - python:3-slim + boto3 + requests (or a prebuilt image)
   - list bucket → for each object: parse the raw `.eml` (stdlib `email`),
     read the `To:`/`Delivered-To:` to pick the owner (docs+chris→chris,
     docs+vanessa→vanessa; default → chris), extract attachments
   - POST each attachment to
     `https://paperless.../api/documents/post_document/` with
     `owner` set + the API token; on success `DeleteObject` from S3
   - idempotent: only deletes after a successful POST
9. Owner IDs: look up by username via the API (`/api/users/`) so we don't
   hardcode DB ids. Vanessa's user must exist (created on her first SSO
   login) before her rule resolves — until then, route her mail to chris
   or skip.

## Decisions to make before building
- apex vs `docs.` subdomain for MX (recommend subdomain).
- Does receiving on the domain interfere with anything currently relying
  on its DNS? (apex MX would.)
- Confirm SES account is OUT of sandbox for inbound (inbound isn't
  sandbox-limited the same way, but verify).

## Notes
- This is NOT the same as real mailboxes — it's an ingestion endpoint.
  Mail sent here only goes into Paperless; there's no inbox to read.
- Keep the poller's blast radius small: bucket-scoped IAM, API token
  scoped to a non-superuser ingestion account if Paperless allows.
