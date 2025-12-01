# Harvester VM DHCP Controller Quick Fix

Use this when VMs are getting new MACs/IPs on restart and DHCP reservations are not sticking. The Helm override below pins the controller and agent to a dev build that fixes the MAC handling issue. This avoids having to bake static MACs into every VM (which doesn’t work well for RKE2/any K8s worker nodes that rely on the DHCP VM controller).

Install/upgrade:
```sh
helm upgrade --install harvester-vm-dhcp-controller harvester/harvester-vm-dhcp-controller \
  -n harvester-system --create-namespace \
  --version 1.6.0 \
  --set image.tag=v1.7.0-dev.1 \
  --set agent.image.tag=v1.7.0-dev.1 \
  --set webhook.image.tag=v1.7.0-dev.1
```

Notes:
- This is a workaround until an official chart/image includes the fix.
- Avoid static MACs if you plan to use the DHCP controller for worker nodes; let the controller manage MAC/IP reservations instead.
