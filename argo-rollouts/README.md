# argo-rollouts RBAC

Cluster-wide RBAC for the manually-installed argo-rollouts controller in
the `argo-rollouts` namespace. The controller itself was installed
~521d ago via raw kubectl-apply against argo-rollouts/v1.7.2 and is
reconciled out-of-band (not under ArgoCD).

This Application manages just the RBAC pieces — when the original
`install-rollouts.yaml` was removed from `argocd-config/` (it had been
deploying a broken duplicate into the `argocd` namespace), ArgoCD
pruned the cluster-wide ClusterRole/ClusterRoleBinding alongside it.
That left the working install in `argo-rollouts/` ns without
permissions, immediate CrashLoopBackOff.

`rbac.yaml` is the upstream RBAC bits from
`https://github.com/argoproj/argo-rollouts/v1.7.2/manifests/install.yaml`,
filtered to just `argo-rollouts*` ClusterRole/ClusterRoleBinding/Role/
RoleBinding objects, with subject namespaces patched to `argo-rollouts`.
