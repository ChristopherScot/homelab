# namespaces

Namespaces live here rather than in the directory of the app that happens
to use them.

Argo tracks every resource in an app's directory as a member of that app,
and the leaf apps set `prune: true` — so a Namespace co-located with a
service becomes prunable, and pruning a Namespace takes everything inside
it. A revert, a bad merge, a rename, or `argocd app delete` without
`--cascade=false` were all enough to trigger it. The `media` namespace was
the worst case: six Longhorn PVCs on a Delete-reclaim StorageClass.

Namespaces also outlive the apps in them, and `media` is shared by five
Applications — so no single app should own it. A namespace's PSA level is
a statement about every workload that will ever land there, including ones
that do not exist yet.

The Application syncing this directory sets `prune: false`. Removing a
file here therefore leaves the namespace in place; deleting a namespace is
deliberate and manual, which is the correct weight for an operation that
is not transactional and cannot be undone.
