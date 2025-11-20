# RKE2 Cluster on Harvester v1.6.1

This repo contains manifests plus a Helm chart that provision an RKE2 management cluster on top of Harvester. Helm drives the VM templates, cloud-init, kube-vip, MetalLB, and (optionally) Rancher Manager; you only need to seed the Harvester-side prerequisites once.

---

## 1. Prerequisites (run against the **Harvester management cluster**)

> You can download Harvester’s kubeconfig from the UI (Top-right menu → **Download kubeconfig**) or, if you have console access, use `/etc/rancher/rke2/rke2.yaml`. Set `export KUBECONFIG=/path/to/harvester-kubeconfig` for the commands below.

1. **Create the guest namespace** (the Helm release defaults to `rke2` – change if needed)
   ```bash
   kubectl create namespace rke2
   ```
   Safe to re-run if it already exists.

2. **Seed OS images** (one time per Harvester cluster)
   ```bash
   kubectl apply -f manifests/image/ubuntu.yaml
   kubectl apply -f manifests/image/rocky9.yaml
   kubectl -n harvester-public get virtualmachineimage  # wait until Ready
   ```
3. **Create guest networks/IP pools** (edit VLAN IDs/bridges first if needed)
   ```bash
   kubectl apply -f manifests/network/networks.yaml
   kubectl apply -f manifests/network/vmnet-vlan2003-ippool.yaml   # requires Harvester DHCP addon
   ```
4. **Cloud-provider ServiceAccount + RBAC** (namespace must match the guest VMs; `rke2` by default)
   ```bash
   kubectl -n rke2 create serviceaccount rke2-mgmt-cloud-provider
   kubectl create clusterrolebinding rke2-cloud-provider-binding \
     --clusterrole=cluster-admin \
     --serviceaccount=rke2:rke2-mgmt-cloud-provider
   ```
5. **Generate the Harvester CCM kubeconfig**
   ```bash
   curl -sfL https://raw.githubusercontent.com/harvester/cloud-provider-harvester/master/deploy/generate_addon.sh \
     | bash -s rke2-mgmt-cloud-provider rke2
   ```
   Copy the `########## cloud config ############` block – you will paste it into `cloudProvider.cloudConfig`.
5. **TLS note** – if you access the Harvester API via IP (e.g., `https://192.168.6.5/...`), either reissue Harvester's management certificate with that IP in its SAN list **or** set `insecure-skip-tls-verify: true` under the `cluster` entry in the generated kubeconfig. Otherwise the CCM cannot connect and the taint is never cleared.
6. **Rancher TLS (cert-manager recommended)** – Rancher requires TLS on its ingress service.
   - **Recommended:** enable the bundled cert-manager installation by setting `certManager.enabled: true` in `custom_values.yaml`. Provide the desired certificate parameters (`certManager.certificate.*`) and make sure a ClusterIssuer/Issuer referenced by `certManager.certificate.issuerRef` already exists. The chart installs cert-manager and creates the `Certificate` resource so the secret is managed automatically.
   - **Manual secret:** if you prefer to manage the secret yourself, generate it before the first `helm upgrade --install`:
   ```bash
   export RANCHER_FQDN=rancher.example.com
   openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
     -keyout tls.key -out tls.crt \
     -subj "/CN=${RANCHER_FQDN}"
   kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret tls rancher-private-tls -n cattle-system \
     --cert=tls.crt --key=tls.key
   ```
   Alternatively, edit `manifests/rancher/tls-secret.yaml` or populate `rancherManager.ingress.tlsSecret.certificate`/`privateKey` in `custom_values.yaml` (with `create: true`) so the chart writes the secret during cloud-init. The secret name must match `rancherManager.ingress.tlsSecretName`.
7. **Optional** – prepare an SSH keypair for cloud-init and ensure the Harvester nodes can reach the internet to download qcow2 images.

---

## 2. Prepare Helm configuration

1. **Copy the default values**
   ```bash
   cp charts/rke2-harvester/values.yaml custom_values.yaml
   ```
2. **Edit `custom_values.yaml`**
   - `image.namespace` / `image.name` – point at the `VirtualMachineImage` you imported.
   - `vmNamePrefix` – friendly VM prefix (defaults to the Helm release name).
   - `storage.*` – disk sizing per role.
   - `replicaCounts.*` and `resources.*` – control the number/sizing of control-plane vs worker VMs.
   - `networks.vm.*` – the Multus NAD namespace/name, static IPs, MACs, DNS, etc. Workers require either static IPv4 addresses here or a NAD backed by DHCP/IPAM; otherwise they will only receive link-local IPv6 addresses. Set `networks.vm.dhcp.worker: true` if you want the chart to emit cloud-init network data that requests DHCP on the worker NIC. When DHCP is enabled the chart automatically generates locally-administered MAC addresses (unless you provide your own via `networks.vm.macAddresses.*`) and creates the matching `VirtualMachineNetworkConfig` resources required by Harvester’s DHCP addon.
   - `kubeVip.*` – enable + configure the control-plane VIP (ensure the IP is reserved).
   - `cloudProvider.cloudConfig` – paste the kubeconfig from the prerequisite step (or pass it with `--set-file`). Add `insecure-skip-tls-verify: true` if you are using the Harvester API IP.
   - `metallb.*` (optional) – enable MetalLB and define address pools if you want service-type `LoadBalancer` support for things like Rancher Manager; use `metallb.values` to pass additional upstream Helm settings (for example `speaker.frr.enabled: false` for pure L2 deployments).
   - `certManager.*` (optional but recommended) – set `certManager.enabled: true` to have the chart install cert-manager via an RKE2 HelmChart and, if desired, create the `Certificate` custom resource that backs Rancher’s ingress secret. Provide the issuer reference and DNS names that match your Rancher hostname.
   - `rancherManager.ingress.*` – leave `tlsSource` at its default (`rancher`) to have Rancher issue a self-signed CA/ingress certificate. Switch it to `secret` only when the TLS secret already exists (see prerequisite #6) or when you embed the PEM materials via `rancherManager.ingress.tlsSecret`. For cert-manager-managed secrets, keep `tlsSecret.create: false` and point `tlsSecretName` at the Certificate’s target.
   - `vmDeployment.*` – image/backoff for the lightweight kubectl job that sequentially creates the Harvester VMs. Pick an image that includes `/bin/sh` (e.g. `alpine/kubectl:1.34.2`) so the script can run.
   - `harvesterTemplates.enabled` – set `false` if you do **not** want Helm to create/replace Harvester `VirtualMachineTemplate`/`Version` objects (useful when Harvester refuses to delete default template versions during upgrades).
   - `ssh.*`, `rke2.*`, `tlsSANs`, etc., per your environment.
4. **Bootstrap SSH Secret + RBAC** (required for the kubeconfig extraction job)
   ```bash
   kubectl apply -f manifests/bootstrap/ssh-key-secret.yaml   # edit stringData with your private key
   kubectl apply -f manifests/bootstrap/bootstrap-rbac.yaml
   ```

---

## 3. Deploy with Helm

1. **First bootstrap (one control-plane VM)**
   ```bash
   helm upgrade --install rke2 charts/rke2-harvester \
     -n rke2 --create-namespace \
     -f custom_values.yaml
   ```
   Wait for the VM to reach `STATUS=Running`. If `kubeVip.enabled: true`, test it from a Harvester host: `curl -k https://<vip>:6443/version`.

2. **Scale to desired size** – edit `replicaCounts.controlPlane` / `.worker` and re-run the same `helm upgrade --install` command. A post-install hook job re-applies each VM manifest sequentially and prunes obsolete entries, so the final VM count only depends on your values file.

3. **Bootstrap the guest kubeconfig**
   ```bash
   kubectl apply -f manifests/bootstrap/bootstrap-job.yaml
   kubectl -n rke2 logs -f job/rke2-bootstrap
   kubectl -n rke2 get secret rke2-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > rke2.kubeconfig
   export KUBECONFIG=$PWD/rke2.kubeconfig
   ```
   Delete the job afterward with `kubectl delete -f manifests/bootstrap/bootstrap-job.yaml` if you like.

4. **Validate the Harvester CCM** – after the VMs boot, the Harvester cloud-provider pod (`harvester-cloud-provider-*` in `kube-system`) should reach `Running` and the `node.cloudprovider.kubernetes.io/uninitialized` taint should disappear. If it remains, double-check TLS (SANs vs IP) and that the ServiceAccount from the prerequisites exists and has the clusterrolebinding.

> 📝 Still using the manifest-only workflow? Apply `manifests/rke2-config/configmap.yaml` and `manifests/vm-templates/`, then manage your own `VirtualMachine` CRs with `kubectl apply`. Helm users can skip those directories because the chart creates the cloud-config secret, VM templates (when `harvesterTemplates.enabled: true`), and the VM resources for you.

---

## 4. Scaling and Operations

- **Scale up/down:** change `replicaCounts` and rerun `helm upgrade --install ...`.
- **Rolling OS image:** import a new `VirtualMachineImage`, update `image.name`, rerun Helm; Harvester recreates VMs on the new template.
- **CI/CD:** `.gitlab-ci.yml` shows a lint → template → apply → verify pipeline using the same chart.
- **Hooks:** the chart uses two Helm hooks:
  - `post-install/post-upgrade` job – applies each VM manifest sequentially (control-planes first, then workers) and deletes any extra VMs. If this job ever fails you can remove it with `kubectl -n <ns> delete job <release>-rke2-harvester-vm-apply` before rerunning Helm.
  - `pre-delete` job – removes all VMs and their PVCs with `kubectl delete vm,pvc -l app.kubernetes.io/name=<prefix>`. Helm keeps failed hooks around, so clean up any stale hook jobs/pods before reinstalling.

---

## 5. Cleanup

1. Remove the Helm release and guest namespace (the pre-delete hook deletes the VMs/PVCs first, then Helm removes the remaining resources):
   ```bash
   helm uninstall rke2 -n rke2
   kubectl delete namespace rke2
   ```
2. Optionally remove any cluster-scoped objects you created earlier (e.g. the CCM clusterrolebinding):
   ```bash
   kubectl -n harvester-public delete virtualmachineimage rocky-9-cloudimg
   kubectl -n harvester-public delete virtualmachineimage ubuntu-22.04-cloudimg
   kubectl delete -f manifests/network/networks.yaml
   kubectl delete -f manifests/network/vmnet-vlan2003-ippool.yaml
   kubectl delete clusterrolebinding rke2-cloud-provider-binding
   kubectl -n rke2 delete serviceaccount rke2-mgmt-cloud-provider
   ```

Recreate the namespace/service account/bindings if you deploy again later.

> ℹ️ All CRDs referenced here match Harvester v1.6.1 (`VirtualMachineImage`, `VirtualMachineTemplate`, etc.).
*** End Patch
PATCH
