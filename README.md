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
| `manifests/rke2-config/` | Cloud-init `Secret` that stores the shared RKE2 configuration (token, CNI, runcmd). |
| `manifests/vm-templates/` | Harvester `VirtualMachineTemplate` + `VirtualMachineTemplateVersion` definitions for control-plane and worker nodes (anchored to the shared cloud-init secret and networks). |
| `manifests/bootstrap/` | Job that copies the kubeconfig off the first control-plane VM into a Secret once the VM is reachable. |
| `charts/rke2-harvester/` | Helm chart that parameterizes VM templates, emits the desired number of `VirtualMachine` objects, and wires in shared config/secrets. |
| `.gitlab-ci.yml` | Optional CI pipeline (lint → deploy → verify) for GitOps style rollouts. |

## Prepare Configuration

1. **Namespace (one time):**
   ```bash
   kubectl create namespace rke2
   ```
   Re-run safe if it already exists.

2. **RKE2 cloud-init secret:** edit `manifests/rke2-config/configmap.yaml` (now a Secret) and replace `REPLACE_WITH_RKE2_TOKEN` plus any other settings you need, then apply:
   ```bash
   kubectl apply -f manifests/rke2-config/configmap.yaml
   ```
   The included `runcmd` detects workers by the `-wk-` substring in the VM hostname and installs the RKE2 agent there; every other VM installs the server. Adjust the logic if you change your VM naming scheme.

3. **Bootstrap SSH key:** create and apply the secret *before* running the bootstrap job. It must contain the private key that matches `values.yaml#ssh.publicKey`. You can edit `manifests/bootstrap/ssh-key-secret.yaml` (it includes an inline `stringData` placeholder) and apply it:
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

3. **Cloud images:** choose which OS images you will boot (Ubuntu or Rocky). Apply each manifest after confirming the URL is still valid:
   ```bash
   kubectl apply -f manifests/image/ubuntu.yaml
   kubectl apply -f manifests/image/rocky9.yaml
   kubectl -n harvester-system get virtualmachineimage
   ```
   Wait for the `Ready` condition before proceeding.


4. **VM network + optional DHCP IP pool:** apply the bundled Multus definitions (Harvester treats NADs with the `network.harvesterhci.io/*` labels as VM networks) and, if you need managed DHCP, the IPPool for VLAN 2003:
   ```bash
   kubectl apply -f manifests/network/networks.yaml
   kubectl apply -f manifests/network/vmnet-vlan2003-ippool.yaml   # requires Harvester DHCP addon
   ```
   These manifests create NADs bound to Harvester’s built-in `mgmt` cluster network/bridge (`mgmt-br`). If your hosts use a different cluster network, change the `network.harvesterhci.io/clusternetwork` label and the `"bridge"` value in `manifests/network/networks.yaml` before applying. The chart currently binds every VM nic to the VLAN 2003 network (with DHCP supplied by `vmnet-vlan2003-ippool.yaml`); VLAN 1003 remains in the repo as an example if you need to introduce an out-of-band network later.

5. **VirtualMachine templates + versions (kubectl workflow):** the manifests under `manifests/vm-templates/` now register both the `VirtualMachineTemplate` shell and the `VirtualMachineTemplateVersion` that contains the kubevirt spec (cloud-init secret, networks, disk layouts). Tweak the CPU/memory/storage or NAD names if your environment differs, then apply the directory:
   ```bash
   kubectl apply -f manifests/vm-templates/
   ```

## Deployment Options

### Option A – Render with Helm, Apply with kubectl

This keeps your deployment as pure manifests but lets Helm handle templating:

1. Copy `charts/rke2-harvester/values.yaml` to a working file (e.g., `my-values.yaml`) and set:
   - `image.namespace` / `image.name` to the Harvester `VirtualMachineImage` you imported (default is `harvester-public/rocky-9-cloudimg`).
   - `vmNamePrefix` if you want a friendlier VM name prefix (falls back to the Helm release name).
   - `storage.*` for disk policy. Leave `storage.className` empty to let Harvester apply the image-specific backing StorageClass (recommended). `storage.size` remains the fallback, while `storage.controlPlaneSize` / `storage.workerSize` let you size each role separately (defaults: 30 Gi for control-plane, 150 Gi for workers).
   - `replicaCounts.*` plus `resources.controlPlane` / `.worker` to match the node counts and sizing you expect (workers default to `0` so you can bring them online later, e.g., after Rancher Manager is deployed).
   - `networks.vm.*` to the namespace/name of the Multus `NetworkAttachmentDefinition` the VMs should attach to (defaults to VLAN 2003).
   - `ssh.publicKey`, optional `ssh.password` (if you want console login), `rke2.token`, `rke2.version`, etc.
2. Render the chart and apply:
   ```bash
   helm template rke2 charts/rke2-harvester \
     -f my-values.yaml \
     --namespace rke2 \
     > rendered.yaml

   kubectl apply -f rendered.yaml
   ```
   The render includes the Harvester templates/template-versions plus the `kubevirt.io/v1` `VirtualMachine` CRs; once applied, Harvester uses the `harvesterhci.io/volumeClaimTemplates` annotation on each VM to create the backing PVCs from your selected image and boot every VM.

 ### Option B – Manage as a Helm Release

If you prefer Helm to keep track of revisions (and to make scaling declarative), install the chart directly:

```bash
helm upgrade --install rke2 charts/rke2-harvester \
  -n rke2 --create-namespace \
  -f my-values.yaml
```

Helm stores release state so `helm upgrade` automatically adds/removes `VirtualMachine` objects when you change `replicaCounts`.

Regardless of whether you use Option A or Option B, you still need to:

- Apply the bootstrap SSH Secret (`kubectl apply -f manifests/bootstrap/ssh-key-secret.yaml` or create it manually).
- Apply the bootstrap RBAC (`kubectl apply -f manifests/bootstrap/bootstrap-rbac.yaml`).
- Run the bootstrap job after the first control-plane VM is Running to extract the kubeconfig.

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

Remove the Helm release (or delete the rendered manifests) and clean up supporting objects:

```bash
helm uninstall rke2 -n rke2        # or kubectl delete -f rendered.yaml
kubectl delete namespace rke2
kubectl delete virtualmachineimage rocky-9-cloudimg -n harvester-system
kubectl delete virtualmachineimage ubuntu-22.04-cloudimg -n harvester-system
```

> ℹ️ All CRDs and resource kinds referenced here match the Harvester v1.6.1 chart under `deploy/charts/harvester-crd` (notably `VirtualMachineImage` instead of the legacy `Image` resource).
