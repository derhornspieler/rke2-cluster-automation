# DeepFlow Helm Wrapper for RKE2

This chart is now a thin wrapper around the official [DeepFlow Helm chart](https://deepflowio.github.io/deepflow). It contains **no** Harvester-specific templates or integrations—the wrapper simply pins the upstream chart as a dependency so you can version-control the values you want to apply to your RKE2 cluster.

## What’s in the repo?
```
harvester-network-monitoring-v2/
├── Chart.yaml     # Declares dependency on deepflow/deepflow
├── Chart.lock     # Generated after helm dependency update
├── charts/        # Contains the downloaded deepflow chart archive
└── values.yaml    # Minimal defaults (override under the `deepflow` key)
```
Everything else (Deployments, DaemonSets, Grafana dashboards, etc.) is delivered by the upstream DeepFlow chart.

## Prerequisites
1. `kubectl` context pointing at your RKE2 cluster (e.g. `kubectl config use-context rke2`).
2. Helm 3.8 or newer.
3. A storage class available for ClickHouse/MySQL PVCs. Override `deepflow.global.storageClass` if you need something other than the cluster default.
4. Optional: a Service LoadBalancer implementation if you plan to expose Grafana via LoadBalancer; otherwise the default NodePort works.

## Install / upgrade
```bash
cd harvester-network-monitoring-v2
helm dependency update                    # downloads deepflow/deepflow
kubectl create namespace deepflow         # once per cluster
helm upgrade --install deepflow ./ \
  -n deepflow \
  -f values.yaml                          # or -f custom-values.yaml
```
The release installs the complete DeepFlow stack (agents, server, ClickHouse, MySQL, Grafana) into the `deepflow` namespace.

### Customising DeepFlow
All upstream values go under the `deepflow` key. Example overrides (`custom-values.yaml`):
```yaml
deepflow:
  global:
    storageClass: longhorn
    replicas: 2
  grafana:
    service:
      type: LoadBalancer
      loadBalancerIP: 172.16.2.50
  deepflow-agent:
    tolerations:
      - operator: Exists
```
Apply with:
```bash
helm upgrade --install deepflow ./ -n deepflow -f custom-values.yaml
```
View all available options via `helm show values deepflow/deepflow`.

## Validation
```bash
kubectl get pods -n deepflow
kubectl get svc -n deepflow deepflow-grafana   # actual service name is release-dependent
```
Grafana listens on the NodePort or LoadBalancer you configured, and the DeepFlow agents run as a DaemonSet across your RKE2 nodes.

## Uninstall
```bash
helm uninstall deepflow -n deepflow
kubectl delete namespace deepflow             # optional, removes PVCs as well
```
Because this wrapper delegates everything to the upstream chart, future upgrades follow the same `helm upgrade --install …` workflow you would use with `deepflow/deepflow` directly.
