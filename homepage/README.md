# Homepage dashboard

Self-hosted dashboard at https://home.chrisscotmartin.com that auto-discovers
services from their Ingress annotations across the cluster.

## Adding a service

Annotate the service's Ingress:

```yaml
metadata:
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Sonarr"
    gethomepage.dev/description: "TV library manager"
    gethomepage.dev/group: "Media"
    gethomepage.dev/icon: "sonarr.png"
    # Optional: enable a service-specific widget
    gethomepage.dev/widget.type: "sonarr"
    gethomepage.dev/widget.url: "http://sonarr.media.svc.cluster.local:8989"
    gethomepage.dev/widget.key: "{{ secret-ref or hardcoded api key }}"
```

The annotation `gethomepage.dev/enabled: "true"` is the gate. Without it Homepage
ignores the ingress.

Icons available at https://github.com/walkxcode/dashboard-icons (use the
filename, e.g. `sonarr.png`).

## Static config

Bookmarks, search, weather widget, etc. live in the chart values
(`app-of-apps/apps/homepage.yaml`). Auto-discovered services don't.

## Where the RBAC lives

The chart creates a ClusterRole that gives Homepage read-only access across
all namespaces. It can get/list/watch resources used for discovery and display,
including Ingresses, Services, Pods, and Namespaces, and it can also read
pod/node metrics. It does NOT have write permission on anything.
