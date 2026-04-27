# ingress-nginx

ArgoCD-managed install of ingress-nginx. Service is configured with
`metallb.universe.tf/loadBalancerIPs: 192.168.50.225` so MetalLB
hands back the same LB IP every time and existing DNS records keep
working.

## Why these values?

- `controller.config.allow-snippet-annotations: "true"` and
  `annotations-risk-level: Critical` — required for the
  `nginx.ingress.kubernetes.io/auth-snippet` annotation used by the
  arr-stack ingresses to forward auth headers to Authelia.
- `controller.service.type: LoadBalancer` with the metallb IP
  annotation — preserves `192.168.50.225` so all existing DNS
  records (Pi-hole `*.home.chrisscotmartin.com` + `*.lab`) keep
  resolving without a DNS update.
- `controller.ingressClassResource.default: false` — leave the
  default IngressClass setting alone. Existing ingresses use
  `ingressClassName: external` (defined in `frontdoor/class.yaml`),
  not the chart's `nginx`.
- `controller.service.externalTrafficPolicy: Local` — preserves
  source IPs on requests, useful for IP-based access control later.

## Adoption note (one-time, when first introducing this Application)

The pre-existing ingress-nginx install was applied via `kubectl apply`
from `metallb/main` (no Helm metadata). To let Helm/ArgoCD adopt
those resources cleanly, either:

1. Delete the old install (`kubectl delete ns ingress-nginx`) and
   let ArgoCD recreate. ~30s of ingress downtime.
2. Pre-stamp every resource with Helm ownership annotations, then
   sync ArgoCD. No downtime but more fragile.

Past this initial adoption, ArgoCD owns the install end-to-end.
