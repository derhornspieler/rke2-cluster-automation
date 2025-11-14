# RKE2 Cluster on Harvester v1.6.1

This repository contains Kubernetes manifests and a small Helm chart that let you stand up an RKE2 cluster on top of a Harvester v1.6.1 installation. It handles VM images, shared networking, bootstrap configuration, and the VirtualMachine resources that Harvester schedules. The same assets can be applied directly with `kubectl` or managed as a Helm release to enable declarative scaling.

## Prerequisites

- Harvester 1.6.1 cluster with the `harvesterhci.io/{virtualmachineimages,virtualmachinetemplates,virtualmachines}` CRDs installed.
- `kubectl` 1.27+ and `helm` 3.12+ pointed at the Harvester management cluster (`export KUBECONFIG=/path/to/harvester/kubeconfig`).
- SSH keypair that the cloud-init snippets can use (optional but recommended).
- Outbound network access from Harvester hosts to download qcow2 cloud images.

## Repository Layout

| Path | Purpose |
| ---- | ------- |
| `manifests/image/` | Harvester `VirtualMachineImage` objects (Ubuntu, Rocky). Apply once to seed the image catalog. |
| `manifests/network/` | Multus `NetworkAttachmentDefinition` objects plus optional DHCP `IPPool` (ships VLAN 2003 + VLAN 1003 examples). |
| `manifests/rke2-config/` | Cloud-init `Secret` for the pure `kubectl apply` workflow. The Helm chart renders the same data from `values.yaml`, so Helm users can skip these manifests. |
| `manifests/vm-templates/` | Harvester `VirtualMachineTemplate` + `VirtualMachineTemplateVersion` definitions for the manifest-only workflow (Helm renders these objects on the fly). |
| `manifests/bootstrap/` | Job that copies the kubeconfig off the first control-plane VM into a Secret once the VM is reachable. |
| `charts/rke2-harvester/` | Helm chart that parameterizes VM templates, emits the desired number of `VirtualMachine` objects, and wires in shared config/secrets. |
| `.gitlab-ci.yml` | Optional CI pipeline (lint → deploy → verify) for GitOps style rollouts. |

## What Helm Manages vs. Manual Prep

| Component | Managed by Helm? | Notes |
| --------- | ---------------- | ----- |
| `rke2` namespace | ⚠️ Partially | All chart resources render into the `rke2` namespace. Create it once with `kubectl create namespace rke2` or rely on `helm upgrade --install ... --create-namespace` the first time. |
| Cloud-config Secret (`<release>-rke2-harvester-cloud-config`) | ✅ Yes | Generated from the values file; you no longer need to apply `manifests/rke2-config` when deploying with Helm. |
| `VirtualMachineTemplate` + `VirtualMachineTemplateVersion` | ✅ Yes | Helm renders per-role templates so Harvester can clone VMs consistently. |
| `kubevirt.io/VirtualMachine` objects | ✅ Yes | Replica counts, sizing, and labels are produced directly from your values file. |
| kube-vip static pod | ✅ Optional | Generated automatically when `kubeVip.enabled: true` so every control-plane VM writes the kube-vip manifest into `/var/lib/rancher/rke2/server/manifests/`. |
| `VirtualMachineImage` objects | ❌ Manual | Apply the YAMLs under `manifests/image/` so Harvester can download the cloud images once per cluster. |
| Workload networks + DHCP pools | ❌ Manual | Apply `manifests/network/*.yaml` to create Multus NADs and (optionally) DHCP IPPools. Update the manifests if you use a different VLAN/bridge. |
| Bootstrap SSH Secret, RBAC, and Job | ❌ Manual | Lives under `manifests/bootstrap/`. Helm does not embed private keys, so you must create these objects yourself before running the bootstrap job. |

The split above answers the "one command" question: Helm is responsible for every object tied to the RKE2 VMs themselves (templates, secrets, VMs, optional VIP). Cluster-scoped prerequisites such as images, Multus networks, and your private SSH material remain manual because they typically require elevated privileges and only need to be seeded once per Harvester installation. After those prerequisites exist, standing up or scaling the cluster really is a single `helm upgrade --install ...` invocation.

## Prepare Configuration

1. **Namespace (one time):**
   ```bash
   kubectl create namespace rke2
   ```
   Re-run safe if it already exists (or rely on `helm ... --create-namespace` the first time).

2. **Cloud images:** choose which OS images you will boot (Ubuntu or Rocky). Apply each manifest after confirming the URL is still valid:
   ```bash
   kubectl apply -f manifests/image/ubuntu.yaml
   kubectl apply -f manifests/image/rocky9.yaml
   kubectl -n harvester-public get virtualmachineimage
   ```
   Wait for the `Ready` condition before proceeding. Harvester only downloads each image once, so this is a one-time cluster prep step.

3. **VM network + optional DHCP IP pool:** apply the bundled Multus definitions (Harvester treats NADs with the `network.harvesterhci.io/*` labels as VM networks) and, if you need managed DHCP, the IPPool for VLAN 2003:
   ```bash
   kubectl apply -f manifests/network/networks.yaml
   kubectl apply -f manifests/network/vmnet-vlan2003-ippool.yaml   # requires Harvester DHCP addon
   ```
   These manifests create NADs bound to Harvester’s built-in `mgmt` cluster network/bridge (`mgmt-br`). If your hosts use a different cluster network, change the `network.harvesterhci.io/clusternetwork` label and the `"bridge"` value in `manifests/network/networks.yaml` before applying. The bundled DHCP pool now excludes `192.168.10.5` so that the default control-plane VIP stays reserved; adjust the `exclude` list if you select a different VIP.

4. **Control-plane VIP via kube-vip (recommended):** pick an unused IP on the workload VLAN and reserve it (DHCP exclusion or static mapping). Set `kubeVip.enabled: true`, `kubeVip.address`, `kubeVip.interface`, and (optionally) `kubeVip.image` in your values file. During cloud-init every control-plane VM pulls the kube-vip image, renders the manifest into `/var/lib/rancher/rke2/server/manifests/kube-vip.yaml`, and RKE2 schedules it as a static pod once the kubelet starts. The first control-plane VM automatically removes the `server:` entry from `/etc/rancher/rke2/config.yaml` so it can bootstrap etcd, while subsequent control-plane nodes keep the endpoint and join through the VIP.
5. **Harvester cloud-provider kubeconfig:** the Harvester CCM requires a kubeconfig on disk. Run `generate_addon.sh <serviceaccount> <namespace>` from the [official docs](https://docs.harvesterhci.io/v1.6/rancher/cloud-provider) against your Harvester management cluster, then paste the `########## cloud config ############` output into `cloudProvider.cloudConfig` (or pass it with `--set-file`). The chart writes it to `/var/lib/rancher/rke2/etc/config-files/cloud-provider-config` during cloud-init so the CCM pod can start and clear the `node.cloudprovider.kubernetes.io/uninitialized` taint automatically. A lightweight background script also removes the taint locally after kubelet comes up so the cluster can proceed even if the CCM cannot reach Harvester yet.
6. **(Optional) MetalLB for LoadBalancer services:** enable `metallb.enabled` and define one or more `addressPools`. Helm will drop a MetalLB HelmChart manifest next to kube-vip and Rancher, so cluster services of type `LoadBalancer` get an address immediately. Annotate services with `metallb.universe.tf/address-pool` and `metallb.universe.tf/loadBalancerIPs` to pin specific VIPs (e.g., Rancher).

5. **Bootstrap SSH key + RBAC:** create and apply the secret *before* running the bootstrap job. It must contain the private key that matches `values.yaml#ssh.publicKey`. You can edit `manifests/bootstrap/ssh-key-secret.yaml` (it includes an inline `stringData` placeholder) and apply it:
   ```bash
   kubectl apply -f manifests/bootstrap/ssh-key-secret.yaml
   kubectl apply -f manifests/bootstrap/bootstrap-rbac.yaml
   ```
   or create it from the CLI instead:
   ```bash
   kubectl -n rke2 create secret generic rke2-bootstrap-sshkey \
     --from-file=id_ed25519=/path/to/your/private/key \
     --type=Opaque
   ```

> 📝 Still using the manifest-only workflow? Apply `manifests/rke2-config/configmap.yaml` and `manifests/vm-templates/`, then manage your own `VirtualMachine` CRs with `kubectl apply`. Helm users can skip those directories because the chart creates the cloud-config secret, VM templates, and the `kubevirt.io/VirtualMachine` objects for you.

## Deploy with Helm

1. Copy `charts/rke2-harvester/values.yaml` to a working file (e.g., `my-values.yaml`) and set:
   - `image.namespace` / `image.name` to the Harvester `VirtualMachineImage` you imported (default is `harvester-public/rocky-9-cloudimg`).
   - `vmNamePrefix` if you want a friendlier VM name prefix (falls back to the Helm release name).
   - `namespaceOverride` only if you need the chart to manage resources in a namespace different from the Helm release’s namespace (leave empty in most cases so `-n/--namespace` controls it).
   - `storage.*` for disk policy. Leave `storage.className` empty to let Harvester apply the image-specific backing StorageClass (recommended). `storage.size` remains the fallback, while `storage.controlPlaneSize` / `storage.workerSize` let you size each role separately (defaults: 30 Gi for control-plane, 150 Gi for workers).
   - `replicaCounts.*` plus `resources.controlPlane` / `.worker` to match the node counts and sizing you expect (workers default to `0` so you can bring them online later, e.g., after Rancher Manager is deployed).
     Each `resources.<role>` block now accepts optional `maxCpuSockets`, `maxMemoryMi`, and `enableHotplug` fields. When `enableHotplug: true`, the chart annotates the VM with `harvesterhci.io/enableCPUAndMemoryHotplug`, maps `cpuCores`/`memoryMi` to the initial sockets + guest memory, and uses the `max*` values for the `limits`, `cpu.maxSockets`, and `memory.maxGuest` ceilings. Leave `enableHotplug: false` (the default) to keep the legacy fixed sizing where requests equal limits.
   - `networks.vm.*` to the namespace/name of the Multus `NetworkAttachmentDefinition` the VMs should attach to (defaults to VLAN 2003).
     If you need deterministic MACs for the control-plane nodes (so DHCP hands back the same IP), list them under `networks.vm.macAddresses.controlPlane` in the order Helm creates the VMs (`-cp-1`, `-cp-2`, ...). Workers can do the same via `networks.vm.macAddresses.worker` or simply rely on the default random values. Alternatively, populate `networks.vm.staticIPs.*` along with `networks.vm.prefix`, `.gateway`, and `.nameservers` to have the chart inject per-VM `networkData`. Each VM then boots with a netplan stanza (no DHCP dependency) and you can hand out exact addresses such as `controlPlane: [192.168.10.3, 192.168.10.4, 192.168.10.5]`.
   - `kubeVip.*` to control the VIP automation. Set `kubeVip.address` to the reserved IP, `kubeVip.interface` to the NIC inside the guest (default `eth0`), optionally provide `kubeVip.cidr` if the interface prefix cannot be auto-detected (e.g., when using `noprefixroute` netplan entries), and keep `kubeVip.namespace`/`kubeVip.image` aligned with your needs. When `kubeVip.rbac.create: true` (the default) the chart also provisions a matching ServiceAccount/ClusterRole/ClusterRoleBinding and the static manifest references that service account so leader election can update the `plndr-cp-lock` Lease without extra manual steps.
   - `tlsSANs` to inject additional API/VIP DNS names or IPs into the generated RKE2 certificate bundle (the VIP is added automatically when enabled).
   - `ssh.publicKey`, optional `ssh.password` (if you want console login), `rke2.token`, `rke2.version`, etc.
   Store your overrides in a dedicated file (for example `custom_values.yaml`) so you can keep secrets out of version control. It is common to keep two variants: one that sets `replicaCounts.controlPlane: 1` for the very first bootstrap, and another with your steady-state replica counts for subsequent upgrades.
2. Bootstrap with a single control-plane VM first by setting `replicaCounts.controlPlane: 1`, then install or upgrade the release:
   ```bash
   helm upgrade --install rke2 charts/rke2-harvester \
     -n rke2 --create-namespace \
     -f my-values.yaml
   ```
   Wait for the VM to reach `Running`, confirm RKE2 is healthy, and (if you enabled the VIP) test `curl -k https://<vip>:6443/version` from a Harvester host to ensure kube-vip is answering.

3. Scale to your desired size by editing `replicaCounts.controlPlane` / `.worker` in the same values file and re-running the identical `helm upgrade --install` command. Helm reconciles the VM set while preserving existing PVCs.

4. Provide the Harvester CCM kubeconfig by running the upstream script against your Harvester management cluster (requires a service-account token with access to the namespace where these VMs live):
   ```bash
   curl -sfL https://raw.githubusercontent.com/harvester/cloud-provider-harvester/master/deploy/generate_addon.sh \\
     | bash -s harvester-cloud-provider hvst-mgmt
   ```
   Copy the `########## cloud config ############` output into `cloudProvider.cloudConfig` (or feed it via `--set-file cloudProvider.cloudConfig=/path/to/file`). The chart writes it to `/var/lib/rancher/rke2/etc/config-files/cloud-provider-config` so the Harvester CCM pod can start and automatically remove the `node.cloudprovider.kubernetes.io/uninitialized` taint.

5. (Optional) Enable MetalLB by setting `metallb.enabled: true` and defining address pools that cover your desired LoadBalancer VIP range. The chart renders a MetalLB HelmChart manifest into `/var/lib/rancher/rke2/server/manifests/metallb.yaml`, so the controller deploys alongside kube-vip. Annotate services (e.g., Rancher) with `metallb.universe.tf/address-pool` and `metallb.universe.tf/loadBalancerIPs` to pin them to specific IPs.

Regardless of the replica count, you still need to:

- Apply the bootstrap SSH Secret (`kubectl apply -f manifests/bootstrap/ssh-key-secret.yaml` or create it manually).
- Apply the bootstrap RBAC (`kubectl apply -f manifests/bootstrap/bootstrap-rbac.yaml`).
- Run the bootstrap job after the first control-plane VM is Running to extract the kubeconfig.
- When using kube-vip, always start with `replicaCounts.controlPlane: 1`, validate the first node (it owns etcd bootstrapping), then re-run `helm upgrade --install ...` with your target control-plane count so the remaining nodes join through the VIP.

## Bootstrap the RKE2 Kubeconfig

1. Ensure the SSH private-key Secret and RBAC are applied:
   ```bash
   kubectl apply -f manifests/bootstrap/ssh-key-secret.yaml   # or create it manually as described earlier
   kubectl apply -f manifests/bootstrap/bootstrap-rbac.yaml
   ```
2. Wait for at least one control-plane VM to reach `STATUS=Running` (`kubectl -n rke2 get vm`).
3. Run the bootstrap job and pull the kubeconfig:
   ```bash
   kubectl apply -f manifests/bootstrap/bootstrap-job.yaml
   kubectl -n rke2 logs -f job/rke2-bootstrap
   kubectl -n rke2 get secret rke2-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > rke2.kubeconfig
   export KUBECONFIG=$PWD/rke2.kubeconfig
   ```

The job can be rerun whenever you rebuild the VMs (it simply updates the Secret). Delete it afterward with `kubectl delete -f manifests/bootstrap/bootstrap-job.yaml` if you prefer to keep the namespace tidy.

## Scaling and Operations

- **Scale up/down:** edit `replicaCounts.controlPlane` or `.worker` in your Helm values file and run `helm upgrade --install ...` again. Helm reconciles the set of `VirtualMachine` CRs, and Harvester powers on/off VMs accordingly.
- **Rolling OS image changes:** import the new `VirtualMachineImage`, update `image.name`, and perform another `helm upgrade`. Harvester will recreate VMs pointing at the new template.
- **CI/CD:** `.gitlab-ci.yml` demonstrates lint → template/apply → verify stages using the same Helm chart and a stored Harvester kubeconfig.

## Cleanup

Remove the Helm release and clean up supporting objects:

```bash
helm uninstall rke2 -n rke2
kubectl delete namespace rke2
kubectl delete virtualmachineimage rocky-9-cloudimg -n harvester-system
kubectl delete virtualmachineimage ubuntu-22.04-cloudimg -n harvester-system
```

> ℹ️ All CRDs and resource kinds referenced here match the Harvester v1.6.1 chart under `deploy/charts/harvester-crd` (notably `VirtualMachineImage` instead of the legacy `Image` resource).
