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
chpasswd:
  list: |
    {{ .Values.ssh.user }}:{{ .Values.ssh.password | default "rocky2025" }}
  expire: false
runcmd:
  - systemctl enable --now qemu-guest-agent.service
  - |
    set -euo pipefail
    INSTALL_TYPE="server"
    SERVICE="rke2-server"
    if hostname | grep -q -- "-wk-"; then
      INSTALL_TYPE="agent"
      SERVICE="rke2-agent"
    fi
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_TYPE} sh -
    systemctl enable ${SERVICE}.service
    systemctl start ${SERVICE}.service
{{- end -}}
