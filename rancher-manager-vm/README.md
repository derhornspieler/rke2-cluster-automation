# Rancher Manager VM (Harvester)

This folder contains everything needed to spin up a Rancher Manager VM on Harvester using a cloud-config secret and a template.

## Files
- `rancher-mgr-cloud-config.yaml` – cloud-init userdata/networkdata secret (type `kubevirt.io/cloud-config`).
- `rancher-mgr-template-version.yaml` – `VirtualMachineTemplate` + `VirtualMachineTemplateVersion` for Rancher Manager (immutable once created).
- `rancher-mgr.yaml` – VM manifest that references the template version and the root disk volume template (sets imageId/size/sc/class).

## Apply order (fresh setup)
1) Create cloud-config secret:  
   `kubectl apply -f rancher-manager-vm/rancher-mgr-cloud-config.yaml`
2) Recreate template + version (delete existing if present, template versions cannot be patched):  
   `kubectl delete virtualmachinetemplateversion rancher-mgr-template-v1 -n hvst-mgmt --ignore-not-found`  
   `kubectl delete virtualmachinetemplate rancher-mgr-template -n hvst-mgmt --ignore-not-found`  
   `kubectl apply -f rancher-manager-vm/rancher-mgr-template-version.yaml`
3) Update `harvesterhci.io/imageId` in `rancher-mgr.yaml` if needed (currently `harvester-public/rocky-9-cloudimg`).
4) Create/update the VM:  
   `kubectl apply -f rancher-manager-vm/rancher-mgr.yaml`
5) (Re)create the VM instance so cloud-init picks up the secret and the VM uses the template version.

## Notes
- Template versions are immutable—change requires creating a new version and pointing the VM annotation to it.
- Root disk PVC is created from `harvesterhci.io/volumeClaimTemplates`; PVCs are retained after VM deletion (delete manually if you want cleanup).
- Network is set to `hvst-mgmt/vlan12`; adjust in template and VM manifests if you need a different network or MAC.***
