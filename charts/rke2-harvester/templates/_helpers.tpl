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
{{- $address := .address | default "" -}}
{{- $prefix := int (default 24 .prefix) -}}
{{- $gateway := .gateway | default "" -}}
{{- $dns := .dns | default (list) -}}
{{- $interface := .interface | default "eth0" -}}
{{- $secondary := .secondary | default (dict) -}}
{{- $secondaryAddress := $secondary.address | default "" -}}
{{- $secondaryPrefix := int (default 24 $secondary.prefix) -}}
{{- $secondaryInterface := $secondary.interface | default "" -}}
{{- $secondaryRoutes := $secondary.routes | default (list) -}}
version: 2
ethernets:
  {{ $interface }}:
{{- if $address }}
    dhcp4: false
    addresses:
      - {{ printf "%s/%d" $address $prefix }}
{{- else }}
    dhcp4: true
{{- end }}
{{- if and $gateway $address }}
    gateway4: {{ $gateway }}
{{- end }}
{{- if and $dns $address }}
    nameservers:
      addresses:
{{- range $dns }}
        - {{ . }}
{{- end }}
{{- end }}
{{- if and $secondaryInterface $secondaryAddress }}
  {{ $secondaryInterface }}:
    dhcp4: false
    addresses:
      - {{ printf "%s/%d" $secondaryAddress $secondaryPrefix }}
{{- if $secondaryRoutes }}
    routes:
{{- range $route := $secondaryRoutes }}
{{- if $route.to }}
      - to: {{ $route.to }}
{{- if $route.via }}
        via: {{ $route.via }}
{{- end }}
{{- if $route.metric }}
        metric: {{ $route.metric }}
{{- end }}
{{- if $route.scope }}
        scope: {{ $route.scope }}
{{- end }}
{{- if $route.table }}
        table: {{ $route.table }}
{{- end }}
{{- if hasKey $route "onlink" }}
        on-link: {{ $route.onlink }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "rke2-harvester.generatedMac" -}}
{{- $vmName := .vmName -}}
{{- $namespace := .namespace | default "" -}}
{{- $seed := printf "%s/%s" $namespace $vmName -}}
{{- $hash := sha256sum $seed | lower -}}
{{- $p2 := substr 0 2 $hash -}}
{{- $p3 := substr 2 4 $hash -}}
{{- $p4 := substr 4 6 $hash -}}
{{- $p5 := substr 6 8 $hash -}}
{{- $p6 := substr 8 10 $hash -}}
{{- printf "02:%s:%s:%s:%s:%s" $p2 $p3 $p4 $p5 $p6 -}}
{{- end -}}

{{- define "rke2-harvester.virtualMachine" -}}
{{- $vm := . -}}
{{- $macAddr := $vm.macAddr -}}
{{- if and (not $macAddr) $vm.forceDhcp }}
{{- $macAddr = include "rke2-harvester.generatedMac" (dict "vmName" $vm.vmName "namespace" $vm.namespace) -}}
{{- end }}
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: {{ $vm.vmName }}
  namespace: {{ $vm.namespace }}
  labels:
    app.kubernetes.io/name: {{ $vm.namePrefix }}
    app.kubernetes.io/component: {{ $vm.component }}
    harvesterhci.io/vmName: {{ $vm.vmName }}
  annotations:
    harvesterhci.io/volumeClaimTemplates: |-
{{ include "rke2-harvester.volumeClaimTemplates" (dict "pvcName" $vm.pvcName "imageID" $vm.imageID "storageClass" $vm.storageClass "accessMode" $vm.accessMode "volumeMode" $vm.volumeMode "storageSize" $vm.storageSize) | indent 6 }}
{{- if $vm.enableHotplug }}
    harvesterhci.io/enableCPUAndMemoryHotplug: "true"
{{- end }}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $vm.namePrefix }}
        app.kubernetes.io/component: {{ $vm.component }}
        harvesterhci.io/rke2-role: {{ $vm.component }}
        harvesterhci.io/vmName: {{ $vm.vmName }}
    spec:
      hostname: {{ $vm.vmName }}
      evictionStrategy: LiveMigrateIfPossible
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ $vm.namePrefix }}
            app.kubernetes.io/component: {{ $vm.component }}
      domain:
        cpu:
{{- if $vm.enableHotplug }}
          sockets: {{ $vm.cpuCores }}
          cores: 1
          threads: 1
          maxSockets: {{ $vm.cpuMaxSockets }}
{{- else }}
          cores: {{ $vm.cpuCores }}
{{- end }}
        resources:
          limits:
            memory: {{ $vm.memoryLimit }}
            cpu: {{ $vm.cpuLimit }}
          requests:
            memory: {{ $vm.memoryRequest }}
            cpu: {{ $vm.cpuCores }}
{{- if $vm.enableHotplug }}
        memory:
          guest: {{ $vm.memoryRequest }}
          maxGuest: {{ $vm.memoryMax }}
{{- end }}
        devices:
          autoattachPodInterface: false
          disks:
          - name: rootdisk
            bootOrder: 1
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: primary
            bridge: {}
            model: virtio
{{- if $macAddr }}
            macAddress: {{ $macAddr }}
{{- end }}
{{- if $vm.rancherEnabled }}
          - name: rancher
            bridge: {}
            model: virtio
{{- end }}
      networks:
      - name: primary
        multus:
          networkName: {{ $vm.vmNetwork }}
{{- if $vm.rancherEnabled }}
      - name: rancher
        multus:
          networkName: {{ $vm.rancherNetwork }}
{{- end }}
      volumes:
      - name: rootdisk
        persistentVolumeClaim:
          claimName: {{ $vm.pvcName }}
      - name: cloudinitdisk
        cloudInitNoCloud:
          secretRef:
            name: {{ $vm.cloudConfig }}
{{- if or $vm.staticIP $vm.rancherHasIP $vm.forceDhcp }}
          networkData: |
{{- $secondary := dict -}}
{{- if $vm.rancherHasIP }}
{{- $_ := set $secondary "address" $vm.rancherIP -}}
{{- $_ := set $secondary "prefix" $vm.rancherPrefix -}}
{{- $_ := set $secondary "interface" $vm.rancherInterface -}}
{{- $_ := set $secondary "routes" $vm.rancherRoutes -}}
{{- end }}
{{ include "rke2-harvester.networkData" (dict "address" $vm.staticIP "prefix" $vm.prefix "gateway" $vm.gateway "dns" $vm.dns "interface" $vm.netInterface "secondary" $secondary) | indent 12 }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.kubeVipRBACManifest" -}}
{{- $vip := .Values.kubeVip | default dict -}}
{{- $enabled := and ($vip.enabled | default false) $vip.address -}}
{{- if and $enabled ($vip.rbac.create | default true) -}}
{{- $namespace := default "kube-system" $vip.namespace -}}
{{- $defaultSA := printf "%s-kube-vip" (include "rke2-harvester.fullname" .) -}}
{{- $serviceAccount := default $defaultSA $vip.serviceAccountName -}}
{{- $resourceName := printf "%s-kube-vip" (include "rke2-harvester.fullname" .) -}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $serviceAccount }}
  namespace: {{ $namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $resourceName }}
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "nodes"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $resourceName }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $resourceName }}
subjects:
  - kind: ServiceAccount
    name: {{ $serviceAccount }}
    namespace: {{ $namespace }}
{{- end -}}
{{- end -}}

{{- define "rke2-harvester.rancherValues" -}}
{{- $rm := .Values.rancherManager | default (dict) -}}
{{- $values := dict -}}
{{- $_ := set $values "hostname" ($rm.hostname | default "") -}}
{{- if $rm.bootstrapPassword }}
{{- $_ := set $values "bootstrapPassword" $rm.bootstrapPassword -}}
{{- end }}
{{- $_ := set $values "replicas" ($rm.replicas | default 3) -}}
{{- $ing := $rm.ingress | default (dict) -}}
{{- $tls := dict "source" ($ing.tlsSource | default "rancher") -}}
{{- if $ing.tlsSecretName }}
{{- $_ := set $tls "secretName" $ing.tlsSecretName -}}
{{- end }}
{{- $ingress := dict "tls" $tls -}}
{{- if $ing.extraAnnotations }}
{{- $_ := set $ingress "extraAnnotations" $ing.extraAnnotations -}}
{{- end }}
{{- if gt (len $ingress) 0 }}
{{- $_ := set $values "ingress" $ingress -}}
{{- end }}
{{- $svc := $rm.service | default (dict) -}}
{{- $service := dict -}}
{{- $_ := set $service "type" ($svc.type | default "LoadBalancer") -}}
{{- if $svc.loadBalancerIP }}
{{- $_ := set $service "loadBalancerIP" $svc.loadBalancerIP -}}
{{- end }}
{{- if $svc.annotations }}
{{- $_ := set $service "annotations" $svc.annotations -}}
{{- end }}
{{- $_ := set $values "service" $service -}}
{{- $extraEnv := $rm.extraEnv | default (list) -}}
{{- if gt (len $extraEnv) 0 }}
{{- $_ := set $values "extraEnv" $extraEnv -}}
{{- end }}
{{ toYaml $values }}
{{- end -}}

{{- define "rke2-harvester.rancherHelmChart" -}}
{{- $rm := .Values.rancherManager | default (dict) -}}
{{- $helmNS := $rm.helmChartNamespace | default "kube-system" -}}
{{- $targetNS := $rm.namespace | default "cattle-system" -}}
{{- $repo := $rm.chartRepo | default "https://releases.rancher.com/server-charts/latest" -}}
{{- $chart := $rm.chartName | default "rancher" -}}
{{- $releaseName := printf "%s-rancher" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: {{ $releaseName }}
  namespace: {{ $helmNS }}
spec:
  chart: {{ $chart }}
  repo: {{ $repo | quote }}
  targetNamespace: {{ $targetNS }}
{{- if $rm.chartVersion }}
  version: {{ $rm.chartVersion | quote }}
{{- end }}
  valuesContent: |
{{ include "rke2-harvester.rancherValues" . | indent 4 }}
{{- end -}}

{{- define "rke2-harvester.metallbValues" -}}
{{- $mlb := .Values.metallb | default (dict) -}}
{{- if $mlb.valuesContent }}
{{ $mlb.valuesContent }}
{{- else if $mlb.values }}
{{ toYaml $mlb.values }}
{{- else }}
{}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.metallbHelmChart" -}}
{{- $mlb := .Values.metallb | default (dict) -}}
{{- $helmNS := $mlb.helmChartNamespace | default "kube-system" -}}
{{- $targetNS := $mlb.namespace | default "metallb-system" -}}
{{- $repo := $mlb.chartRepo | default "https://metallb.github.io/metallb" -}}
{{- $chart := $mlb.chartName | default "metallb" -}}
{{- $releaseName := printf "%s-metallb" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: {{ $releaseName }}
  namespace: {{ $helmNS }}
spec:
  chart: {{ $chart }}
  repo: {{ $repo | quote }}
  targetNamespace: {{ $targetNS }}
{{- if $mlb.chartVersion }}
  version: {{ $mlb.chartVersion | quote }}
{{- end }}
  valuesContent: |
{{ include "rke2-harvester.metallbValues" . | indent 4 }}
{{- end -}}

{{- define "rke2-harvester.certManagerValues" -}}
{{- $cm := .Values.certManager | default (dict) -}}
{{- if $cm.valuesContent }}
{{ $cm.valuesContent }}
{{- else if $cm.values }}
{{ toYaml $cm.values }}
{{- else }}
{}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.certManagerHelmChart" -}}
{{- $cm := .Values.certManager | default (dict) -}}
{{- $helmNS := $cm.helmChartNamespace | default "kube-system" -}}
{{- $targetNS := $cm.namespace | default "cert-manager" -}}
{{- $repo := $cm.chartRepo | default "https://charts.jetstack.io" -}}
{{- $chart := $cm.chartName | default "cert-manager" -}}
{{- $releaseName := printf "%s-cert-manager" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: {{ $releaseName }}
  namespace: {{ $helmNS }}
spec:
  chart: {{ $chart }}
  repo: {{ $repo | quote }}
  targetNamespace: {{ $targetNS }}
{{- if $cm.chartVersion }}
  version: {{ $cm.chartVersion | quote }}
{{- end }}
  valuesContent: |
{{ include "rke2-harvester.certManagerValues" . | indent 4 }}
{{- if $cm.installCRDs }}
  set:
    installCRDs: "true"
{{- end }}
{{- end -}}

{{- define "rke2-harvester.metallbAddressPoolsYAML" -}}
{{- $mlb := .Values.metallb | default dict -}}
{{- if not ($mlb.enabled | default false) -}}
{{- /* nothing */ -}}
{{- else -}}
{{- $pools := $mlb.addressPools | default list -}}
{{- $targetNS := $mlb.namespace | default "metallb-system" -}}
{{- $chartName := "rke2-harvester" -}}
{{- if .Chart }}
  {{- if .Chart.Name }}
    {{- $chartName = .Chart.Name }}
  {{- end }}
{{- end }}
{{- range $idx, $pool := $pools }}
{{- $poolName := $pool.name | default (printf "%s-pool-%d" $chartName (add $idx 1)) -}}
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: {{ $poolName }}
  namespace: {{ $targetNS }}
spec:
  addresses:
{{- range $addr := $pool.addresses | default list }}
    - {{ $addr }}
{{- end }}
{{- if hasKey $pool "autoAssign" }}
  autoAssign: {{ $pool.autoAssign }}
{{- end }}
{{- if hasKey $pool "avoidBuggyIPs" }}
  avoidBuggyIPs: {{ $pool.avoidBuggyIPs }}
{{- end }}
{{- if $pool.ipAddressPoolSpec }}
{{ toYaml $pool.ipAddressPoolSpec | indent 2 }}
{{- end }}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: {{ printf "%s-l2" $poolName | trunc 63 | trimSuffix "-" }}
  namespace: {{ $targetNS }}
spec:
  ipAddressPools:
    - {{ $poolName }}
{{- if $pool.interfaces }}
  interfaces:
{{- range $iface := $pool.interfaces }}
    - {{ $iface }}
{{- end }}
{{- end }}
{{- if $pool.l2AdvertisementSpec }}
{{ toYaml $pool.l2AdvertisementSpec | indent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.kubeVipStaticManifest" -}}
{{- $vip := .Values.kubeVip -}}
{{- $namespace := default "kube-system" $vip.namespace -}}
{{- $defaultSA := printf "%s-kube-vip" (include "rke2-harvester.fullname" .) -}}
{{- $serviceAccount := default $defaultSA $vip.serviceAccountName -}}
{{- $cidr := $vip.cidr | default "" -}}
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
{{- if $cidr }}
        - name: vip_cidr
          value: {{ printf "%v" $cidr | quote }}
{{- end }}
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
{{- $vipRBAC := and $hasVip ($kubeVip.rbac.create | default true) }}
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
{{- if $vipRBAC }}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip-rbac.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.kubeVipRBACManifest" . | indent 6 }}
{{- end }}
{{- if $hasVip }}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.kubeVipStaticManifest" . | indent 6 }}
{{- end }}
{{- $rm := .Values.rancherManager | default dict -}}
{{- $rancherEnabled := $rm.enabled | default false -}}
{{- $rancherNamespace := $rm.namespace | default "cattle-system" -}}
{{- $mlb := .Values.metallb | default dict -}}
{{- $metallbEnabled := $mlb.enabled | default false -}}
{{- $metallbNamespace := $mlb.namespace | default "metallb-system" -}}
{{- $metallbPools := $mlb.addressPools | default (list) -}}
{{- $cm := .Values.certManager | default dict -}}
{{- $cmEnabled := $cm.enabled | default false -}}
{{- $cmNamespace := $cm.namespace | default "cert-manager" -}}
{{- $certificate := $cm.certificate | default dict -}}
{{- $certSecretName := $certificate.secretName | default "" -}}
{{- $certIssuer := $certificate.issuerRef | default dict -}}
{{- $certCreate := and $cmEnabled ($certificate.create | default false) $certSecretName $rancherNamespace -}}
{{- $ca := $cm.ca | default dict -}}
{{- $caSecret := $ca.secretName | default "" -}}
{{- $caEnabled := and $cmEnabled $rancherEnabled ($ca.create | default false) $caSecret $rancherNamespace -}}
{{- $tlsSecret := $rm.ingress.tlsSecret | default dict -}}
{{- $tlsSecretEnabled := and $rancherEnabled ($tlsSecret.create | default false) $rancherNamespace ($rm.ingress.tlsSecretName | default "") ($tlsSecret.certificate | default "") ($tlsSecret.privateKey | default "") -}}
{{- if and $rancherEnabled $rancherNamespace }}
  - path: /var/lib/rancher/rke2/server/manifests/rancher-namespace.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: {{ $rancherNamespace }}
{{- end }}
{{- if $tlsSecretEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/rancher-tls-secret.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Secret
      metadata:
        name: {{ $rm.ingress.tlsSecretName }}
        namespace: {{ $rancherNamespace }}
      type: kubernetes.io/tls
      stringData:
        tls.crt: |
{{ $tlsSecret.certificate | indent 10 }}
        tls.key: |
{{ $tlsSecret.privateKey | indent 10 }}
{{- end }}
{{- if and $cmEnabled $cmNamespace }}
  - path: /var/lib/rancher/rke2/server/manifests/cert-manager-namespace.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: {{ $cmNamespace }}
{{- end }}
{{- if $cmEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/cert-manager.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.certManagerHelmChart" . | indent 6 }}
{{- end }}
{{- if $caEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/rancher-ca.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: cert-manager.io/v1
      kind: Issuer
      metadata:
        name: {{ $ca.selfSignedIssuerName | default (printf "%s-ca-selfsigned" (include "rke2-harvester.fullname" .)) }}
        namespace: {{ $rancherNamespace }}
      spec:
        selfSigned: {}
      ---
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: {{ $ca.certificateName | default (printf "%s-ca" (include "rke2-harvester.fullname" .)) }}
        namespace: {{ $rancherNamespace }}
      spec:
        isCA: true
        commonName: {{ $ca.commonName | default (printf "%s-ca" (include "rke2-harvester.fullname" .)) }}
        secretName: {{ $caSecret }}
        issuerRef:
          kind: Issuer
          name: {{ $ca.selfSignedIssuerName | default (printf "%s-ca-selfsigned" (include "rke2-harvester.fullname" .)) }}
      ---
      apiVersion: cert-manager.io/v1
      kind: Issuer
      metadata:
        name: {{ $ca.issuerName | default (printf "%s-ca-issuer" (include "rke2-harvester.fullname" .)) }}
        namespace: {{ $rancherNamespace }}
      spec:
        ca:
          secretName: {{ $caSecret }}
{{- end }}
{{- if $certCreate }}
  - path: /var/lib/rancher/rke2/server/manifests/rancher-cert.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: {{ printf "%s-certificate" $rm.ingress.tlsSecretName | trunc 63 | trimSuffix "-" }}
        namespace: {{ $rancherNamespace }}
      spec:
        secretName: {{ $rm.ingress.tlsSecretName }}
{{- if $certificate.commonName }}
        commonName: {{ $certificate.commonName }}
{{- end }}
{{- $dns := $certificate.dnsNames | default list }}
{{- if gt (len $dns) 0 }}
        dnsNames:
{{- range $dnsName := $dns }}
          - {{ $dnsName }}
{{- end }}
{{- end }}
        issuerRef:
          name: {{ $certIssuer.name | default "rancher-ca-issuer" }}
          kind: {{ $certIssuer.kind | default "ClusterIssuer" }}
          group: {{ $certIssuer.group | default "cert-manager.io" }}
{{- end }}
{{- if $rancherEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/rancher-manager.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.rancherHelmChart" . | indent 6 }}
{{- end }}
{{- $cloudProvider := .Values.cloudProvider | default (dict) -}}
{{- if $cloudProvider.cloudConfig }}
  - path: {{ $cloudProvider.configPath | default "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config" }}
    owner: root:root
    permissions: "0644"
    selinux:
      context: system_u:object_r:container_file_t:s0
    content: |
{{ $cloudProvider.cloudConfig | indent 6 }}
{{- end }}
{{- if and $metallbEnabled $metallbNamespace }}
  - path: /var/lib/rancher/rke2/server/manifests/metallb-namespace.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: {{ $metallbNamespace }}
{{- end }}
{{- if $metallbEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/metallb.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.metallbHelmChart" . | indent 6 }}
{{- end }}
{{- if and $metallbEnabled (gt (len $metallbPools) 0) }}
  - path: /var/lib/rancher/rke2/server/manifests/metallb-config.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.metallbAddressPoolsYAML" . | indent 6 }}
{{- end }}
chpasswd:
  list: |
    {{ .Values.ssh.user }}:{{ .Values.ssh.password | default "rocky2025" }}
  expire: false
runcmd:
  - systemctl enable --now qemu-guest-agent.service
{{- if $cloudProvider.cloudConfig }}
  - chcon -t container_file_t {{ $cloudProvider.configPath | default "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config" }} || true
{{- end }}
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
  - |
    cat <<'EOF' >/usr/local/bin/clear-harvester-taint.sh
    #!/bin/bash
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    for i in {1..60}; do
      if kubectl get nodes >/dev/null 2>&1; then
        NODE=$(hostname)
        kubectl taint nodes "$NODE" node.cloudprovider.kubernetes.io/uninitialized:NoSchedule- || true
        exit 0
      fi
      sleep 5
    done
    exit 0
    EOF
    chmod +x /usr/local/bin/clear-harvester-taint.sh
    /usr/local/bin/clear-harvester-taint.sh &
{{- end -}}
