# DeepFlow Harvester Extension Add-on

This folder contains an example Harvester `Addon` manifest that installs the `harvester-network-monitoring` Helm chart through Harvester’s built-in extension framework. The manifest follows the guidance from [docs/developer/addon-development.md](https://docs.harvesterhci.io/v1.6/developer/Add-on-development-guide).

## Packaging workflow

1. Package the Helm chart and publish it in a Helm repository that your Harvester cluster can reach (GitLab Pages, an S3 bucket, or any static HTTP server).

   ```bash
   cd ..
   helm dependency update harvester-network-monitoring-v2
   helm package harvester-network-monitoring-v2 --destination dist
   helm repo index dist --url https://example.com/harvester-network-monitoring
   ```

2. Update `deepflow-addon.yaml` with the hosted repo URL and chart version if they differ.
3. Apply the Add-on manifest to the Harvester cluster:

   ```bash
   kubectl apply -f harvester-addon/deepflow-addon.yaml
   ```

4. Enable/disable the add-on from the Harvester UI or by patching the `spec.enabled` field.

## Notes

- The Add-on is namespaced. The sample manifest deploys the chart into the `deepflow` namespace and creates the Addon resource inside `harvester-system`.
- The ConfigMaps and monitoring resources that the chart creates inside `cattle-monitoring-system` and `cattle-dashboards` are also managed by Helm. Disabling or deleting the Add-on removes them automatically.
- Adjust the `valuesContent` block to override any Helm values required for your environment (for example, a custom storage class or disabling Grafana/Prometheus integration during testing).
