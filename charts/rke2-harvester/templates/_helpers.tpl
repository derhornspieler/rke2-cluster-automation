{{- /*
  Helper functions for the rke2‑harvester chart.
*/ -}}

{{- define "rke2-harvester.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rke2-harvester.volumeClaimTemplates" -}}
{{- $accessMode := .accessMode | default "ReadWriteMany" -}}
{{- $volumeMode := .volumeMode | default "Block" -}}
{{- $storageSize := .storageSize | default "30Gi" -}}
{{- $annotations := dict "harvesterhci.io/imageId" .imageID -}}
{{- $metadata := dict "name" .pvcName "annotations" $annotations -}}
{{- $resources := dict "requests" (dict "storage" $storageSize) -}}
{{- $spec := dict "accessModes" (list $accessMode) "resources" $resources "volumeMode" $volumeMode -}}
{{- if .storageClass }}
{{- $_ := set $spec "storageClassName" .storageClass -}}
{{- end -}}
{{- $template := dict "metadata" $metadata "spec" $spec -}}
{{ toJson (list $template) }}
{{- end -}}

{{- define "rke2-harvester.macForIndex" -}}
{{- $list := .list | default (list) -}}
{{- $idx := .index | default 0 -}}
{{- if and $list (gt (len $list) $idx) -}}
{{- index $list $idx -}}
{{- end -}}
{{- end -}}

{{- define "rke2-harvester.valueForIndex" -}}
{{- $list := .list | default (list) -}}
{{- $idx := .index | default 0 -}}
{{- if and $list (gt (len $list) $idx) -}}
{{- index $list $idx -}}
{{- end -}}
{{- end -}}

{{- define "rke2-harvester.networkData" -}}
{{- $address := .address -}}
{{- $prefix := int (default 24 .prefix) -}}
{{- $gateway := .gateway -}}
{{- $dns := .dns | default (list) -}}
{{- $interface := .interface | default "eth0" -}}
version: 2
ethernets:
  {{ $interface }}:
    dhcp4: false
    addresses:
      - {{ printf "%s/%d" $address $prefix }}
{{- if $gateway }}
    gateway4: {{ $gateway }}
{{- end }}
{{- if $dns }}
    nameservers:
      addresses:
{{- range $dns }}
        - {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.kubeVipStaticManifest" -}}
{{- $vip := .Values.kubeVip -}}
{{- $namespace := default "kube-system" $vip.namespace -}}
{{- $defaultSA := printf "%s-kube-vip" (include "rke2-harvester.fullname" .) -}}
{{- $serviceAccount := default $defaultSA $vip.serviceAccountName -}}
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: {{ $namespace }}
  labels:
    app.kubernetes.io/name: kube-vip
spec:
  serviceAccountName: {{ $serviceAccount }}
  automountServiceAccountToken: true
  hostNetwork: true
  priorityClassName: system-node-critical
  tolerations:
    - operator: Exists
  containers:
    - name: kube-vip
      image: {{ $vip.image }}
      imagePullPolicy: IfNotPresent
      args:
        - manager
      env:
        - name: vip_arp
          value: "true"
        - name: cp_enable
          value: "true"
        - name: svc_enable
          value: "false"
        - name: vip_interface
          value: {{ $vip.interface }}
        - name: vip_address
          value: {{ $vip.address | quote }}
        - name: vip_leaderelection
          value: "true"
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
            - SYS_TIME
{{- end -}}

{{- define "rke2-harvester.userData" -}}
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - cloud-utils-growpart
users:
  - name: {{ .Values.ssh.user }}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [wheel]
    shell: /bin/bash
{{- if .Values.ssh.publicKey }}
    ssh_authorized_keys:
      - {{ .Values.ssh.publicKey | quote }}
{{- end }}
    lock_passwd: false
write_files:
  - path: /etc/rancher/rke2/config.yaml
    owner: root:root
    permissions: "0644"
    content: |
      disable:
        - rke2-snapshot-controller
        - rke2-snapshot-controller-crd
        - rke2-snapshot-validation-webhook
      node-label:
        - harvesterhci.io/managed=true
      token: "{{ .Values.rke2.token }}"
      cni:
        - {{ .Values.rke2.cni }}
      cloud-provider-name: harvester
{{- $kubeVip := .Values.kubeVip | default dict -}}
{{- $hasVip := and ($kubeVip.enabled | default false) $kubeVip.address }}
{{- if $hasVip }}
      server: https://{{ $kubeVip.address }}:9345
{{- end }}
{{- if or $hasVip (gt (len .Values.tlsSANs) 0) }}
      tls-san:
{{- if $hasVip }}
        - {{ $kubeVip.address }}
{{- end }}
{{- range .Values.tlsSANs }}
        - {{ . }}
{{- end }}
{{- end }}
{{- if $hasVip }}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.kubeVipStaticManifest" . | indent 6 }}
{{- end }}
chpasswd:
  list: |
    {{ .Values.ssh.user }}:{{ .Values.ssh.password | default "rocky2025" }}
  expire: false
runcmd:
  - systemctl enable --now qemu-guest-agent.service
  - |
    set -euo pipefail
    HOSTNAME="$(hostname)"
    INSTALL_TYPE="server"
    SERVICE="rke2-server"
    if echo "${HOSTNAME}" | grep -q -- "-cp-1$"; then
      sed -i '/^server:/d' /etc/rancher/rke2/config.yaml
    fi
    if echo "${HOSTNAME}" | grep -q -- "-wk-"; then
      INSTALL_TYPE="agent"
      SERVICE="rke2-agent"
    fi
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_TYPE} sh -
    systemctl enable ${SERVICE}.service
    systemctl start ${SERVICE}.service
{{- end -}}
