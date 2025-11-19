# Harvester Network Monitoring (DeepFlow)

This Helm chart deploys a DeepFlow-based network observability stack onto a Harvester (Kubernetes) cluster:
- DeepFlow agents (DaemonSet) using eBPF on each node
- DeepFlow server (StatefulSet) with MySQL and ClickHouse backends
- Optional DeepFlow App UI Deployment + Service (LoadBalancer or NodePort) for native flow visualization, plus an optional Traefik Ingress with TLS termination
- Optional embedded Traefik ingress controller (if your Harvester cluster doesn’t already provide one)
- Optional kube-vip based Service LoadBalancer so Traefik (and any other LoadBalancer services) can advertise a static VIP even if Harvester’s built-in kube-vip isn’t available to tenant workloads
- ConfigMaps that provision the Rancher Monitoring Grafana instance with a DeepFlow data source and starter dashboard
- ServiceMonitor and PrometheusRule resources so Harvester’s built-in Prometheus scrapes/alerts on DeepFlow

## Directory layout

harvester-network-monitoring/
├── Chart.yaml
├── dashboards/
│   └── deepflow-network-overview.json
├── values.yaml
└── templates/
    ├── deepflow-app-deployment.yaml
    ├── service-deepflow-app.yaml
    ├── deepflow-agent-daemonset.yaml
    ├── deepflow-server-statefulset.yaml
    ├── deepflow-clickhouse-statefulset.yaml
    ├── deepflow-mysql-statefulset.yaml
    ├── service-deepflow.yaml
    ├── service-mysql.yaml
    ├── service-clickhouse.yaml
    ├── grafana-configmaps.yaml
    ├── ingress-deepflow-app.yaml
    ├── traefik-deployment.yaml
    ├── traefik-service.yaml
    ├── traefik-rbac.yaml
    ├── traefik-ingressclass.yaml
    ├── service-lb-kube-vip.yaml
    ├── monitoring-resources.yaml
    ├── networkpolicy-server.yaml
    ├── networkpolicy-databases.yaml
    └── rbac.yaml

## Quick start

```bash
kubectl create namespace deepflow
helm install harvester-netmon ./harvester-network-monitoring -n deepflow
```

(You can also skip the explicit `kubectl create namespace` and pass `--create-namespace`; the chart no longer manages the namespace resource itself.)

After the release is ready, open the **Monitoring → Grafana** link in the Harvester UI. The chart automatically:

- registers a `DeepFlow` Prometheus data source that targets the DeepFlow server API service,
- imports the `DeepFlow Network Overview` dashboard from the ConfigMap inside the `cattle-dashboards` namespace, and
- creates a `ServiceMonitor` plus alerting rules so the existing Prometheus instance scrapes DeepFlow and fires alerts if the server becomes unavailable.
- deploys the optional DeepFlow App UI (listens on port 20418) and exposes it via a LoadBalancer `Service`. Set `deepflowApp.service.loadBalancerIP` to the static kube-vip IP you want to use (or change `deepflowApp.service.type` to `NodePort` and provide `deepflowApp.service.nodePort` if you prefer a NodePort).

The default values assume Harvester’s monitoring stack uses the standard namespaces (`cattle-monitoring-system` and `cattle-dashboards`). Override the namespaces or disable the integrations if your environment differs.

If you do not want to touch Harvester’s namespaces (e.g., for testing outside Harvester), set `grafanaIntegration.enabled=false` and/or `prometheusIntegration.enabled=false`.

## Expose the DeepFlow App UI with Traefik + TLS

By default the DeepFlow App UI is reachable through the Service type you pick under `deepflowApp.service`. If your Harvester cluster already has an ingress controller, enable the ingress block to front the UI with TLS. If it does **not** have one, set `traefik.enabled=true` so this chart deploys a lightweight Traefik instance (Deployment + LoadBalancer Service + `IngressClass`). To front it with Traefik and terminate TLS:

1. Generate a self-signed cert for `deepflow.aegisgroup.ch` (or your domain) and create a TLS secret in the release namespace (example uses `network-monitoring`):

   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout deepflow-app.key -out deepflow-app.crt \
     -subj "/CN=deepflow.aegisgroup.ch"

   kubectl create namespace network-monitoring --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret tls deepflow-app-tls \
     -n network-monitoring \
     --cert=deepflow-app.crt \
     --key=deepflow-app.key
   ```

2. Enable the ingress block in your values:

   ```yaml
   deepflowApp:
     ingress:
       enabled: true
       className: "traefik"
       host: "deepflow.aegisgroup.ch"
       tls:
         enabled: true
         secretName: "deepflow-app-tls"
   ```

3. If your cluster lacks an ingress controller, add this to your values to enable the embedded one:

   ```yaml
   traefik:
     enabled: true
     service:
       type: LoadBalancer
       loadBalancerIP: <static kube-vip IP for ingress>
   ```

4. Install/upgrade the chart with `-n network-monitoring --create-namespace -f custom_values.yaml`.

Traefik will serve HTTPS for `https://deepflow.aegisgroup.ch` using the secret you created and proxy requests to the DeepFlow App Service on port 20418.

### Advertise the Traefik VIP with kube-vip

If your Harvester cluster doesn’t expose a Service LoadBalancer for tenant workloads, enable the embedded kube-vip DaemonSet so the Traefik LoadBalancer service actually announces its `loadBalancerIP`. Add to your values:

```yaml
serviceLB:
  enabled: true
  interface: bond0              # replace with the NIC that carries your mgmt subnet
  addressRange:
    start: 172.16.2.6
    end: 172.16.2.6            # single VIP; use different end IP to create a pool
```

The chart deploys kube-vip as a DaemonSet, along with the necessary RBAC, and limits it to the range you specify. Pick an unused IP on the same subnet/VLAN as your Harvester nodes. Once kube-vip is running, `kubectl get svc harvester-netmon-traefik -o wide` should show the VIP and you’ll be able to reach Traefik (and the DeepFlow UI ingress) from your network.

## Harvester Extension Add-on

The `harvester-addon/` directory shows how to wrap this chart as a Harvester Extension Add-on.  
Follow `docs/developer/addon-development.md` from the Harvester repo, update the sample Addon manifest with the URL to your Helm repo, and apply it to your cluster to expose DeepFlow in the Harvester UI.
