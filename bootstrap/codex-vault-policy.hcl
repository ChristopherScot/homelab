# ESO in codex-pods can read its workspace access token and the existing GitHub identity.
path "kv/data/codex-pods/auth" { capabilities = ["read"] }
path "kv/data/claude-pods/git" { capabilities = ["read"] }
