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
{{- $labels := .labels | default (dict) -}}
{{- $metadata := dict "name" .pvcName "annotations" $annotations -}}
{{- if gt (len $labels) 0 }}
{{- $_ := set $metadata "labels" $labels -}}
{{- end }}
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
{{- $pvcLabels := $vm.pvcLabels | default (dict) -}}
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
{{ include "rke2-harvester.volumeClaimTemplates" (dict "pvcName" $vm.pvcName "imageID" $vm.imageID "storageClass" $vm.storageClass "accessMode" $vm.accessMode "volumeMode" $vm.volumeMode "storageSize" $vm.storageSize "labels" $pvcLabels) | indent 6 }}
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
{{- if and ((.Values.gatewayAPI).enabled | default false) ((.Values.traefik).enabled | default false) }}
{{- $_ := set $service "type" "ClusterIP" -}}
{{- end }}
{{- $_ := set $values "service" $service -}}
{{- $resources := $rm.resources | default dict -}}
{{- if $resources }}
{{- $_ := set $values "resources" $resources -}}
{{- end }}
{{- $extraEnv := $rm.extraEnv | default (list) -}}
{{- $cnpg := .Values.cloudNativePG | default (dict) -}}
{{- if $cnpg.enabled }}
{{- $cluster := $cnpg.cluster | default (dict) -}}
{{- $clusterName := $cluster.name | default "rancher-postgres" -}}
{{- $clusterNS := $cluster.namespace | default "cattle-system" -}}
{{- $owner := $cluster.owner | default "rancher" -}}
{{- $dbName := $cluster.database | default "rancher" -}}
{{- $secretName := "rancher-db-credentials" -}}
{{- if not $cnpg.password }}
{{- $secretName = printf "%s-app" $clusterName -}}
{{- end }}
{{- $dbEnv := list
  (dict "name" "CATTLE_DB_CATTLE_DRIVER" "value" "postgres")
  (dict "name" "CATTLE_DB_CATTLE_HOST" "value" (printf "%s-rw.%s" $clusterName $clusterNS))
  (dict "name" "CATTLE_DB_CATTLE_PORT" "value" "5432")
  (dict "name" "CATTLE_DB_CATTLE_NAME" "value" $dbName)
  (dict "name" "CATTLE_DB_CATTLE_USERNAME" "valueFrom" (dict "secretKeyRef" (dict "name" $secretName "key" "username")))
  (dict "name" "CATTLE_DB_CATTLE_PASSWORD" "valueFrom" (dict "secretKeyRef" (dict "name" $secretName "key" "password")))
-}}
{{- $extraEnv = concat $extraEnv $dbEnv -}}
{{- end }}
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
{{- $gwEnabled := (.Values.gatewayAPI).enabled | default false -}}
{{- if $cm.valuesContent }}
{{ $cm.valuesContent }}
{{- if $gwEnabled }}
extraArgs:
  - --enable-gateway-api
{{- end }}
{{- else if $cm.values }}
{{- $vals := deepCopy $cm.values -}}
{{- if $gwEnabled }}
{{- $existing := $vals.extraArgs | default list -}}
{{- $_ := set $vals "extraArgs" (append $existing "--enable-gateway-api") -}}
{{- end }}
{{ toYaml $vals }}
{{- else }}
{{- if $gwEnabled }}
extraArgs:
  - --enable-gateway-api
{{- else }}
{}
{{- end }}
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

{{- define "rke2-harvester.cnpgValues" -}}
{{- $cnpg := .Values.cloudNativePG | default (dict) -}}
{{- if $cnpg.values }}
{{ toYaml $cnpg.values }}
{{- else }}
{}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.cnpgHelmChart" -}}
{{- $cnpg := .Values.cloudNativePG | default (dict) -}}
{{- $helmNS := $cnpg.helmChartNamespace | default "kube-system" -}}
{{- $targetNS := $cnpg.namespace | default "cnpg-system" -}}
{{- $repo := $cnpg.chartRepo | default "https://cloudnative-pg.github.io/charts" -}}
{{- $chart := $cnpg.chartName | default "cloudnative-pg" -}}
{{- $releaseName := printf "%s-cnpg" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: {{ $releaseName }}
  namespace: {{ $helmNS }}
spec:
  chart: {{ $chart }}
  repo: {{ $repo | quote }}
  targetNamespace: {{ $targetNS }}
  createNamespace: true
{{- if $cnpg.chartVersion }}
  version: {{ $cnpg.chartVersion | quote }}
{{- end }}
  valuesContent: |
{{ include "rke2-harvester.cnpgValues" . | indent 4 }}
{{- end -}}

{{- define "rke2-harvester.cnpgCluster" -}}
{{- $cnpg := .Values.cloudNativePG | default (dict) -}}
{{- $cluster := $cnpg.cluster | default (dict) -}}
{{- $clusterName := $cluster.name | default "rancher-postgres" -}}
{{- $clusterNS := $cluster.namespace | default "cattle-system" -}}
{{- $pg := $cluster.postgresql | default (dict) -}}
{{- $storage := $cluster.storage | default (dict) -}}
{{- $resources := $cluster.resources | default (dict) -}}
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ $clusterName }}
  namespace: {{ $clusterNS }}
spec:
  instances: {{ $cluster.instances | default 3 }}
  bootstrap:
    initdb:
      database: {{ $cluster.database | default "rancher" }}
      owner: {{ $cluster.owner | default "rancher" }}
      dataChecksums: true
  storage:
    size: {{ $storage.size | default "20Gi" }}
{{- if $storage.storageClass }}
    storageClass: {{ $storage.storageClass }}
{{- end }}
{{- if $pg }}
  postgresql:
    parameters:
{{ toYaml $pg | indent 6 }}
{{- end }}
{{- if $resources }}
  resources:
{{ toYaml $resources | indent 4 }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.rancherDBSecret" -}}
{{- $cnpg := .Values.cloudNativePG | default (dict) -}}
{{- $cluster := $cnpg.cluster | default (dict) -}}
{{- $clusterName := $cluster.name | default "rancher-postgres" -}}
{{- $clusterNS := $cluster.namespace | default "cattle-system" -}}
{{- $owner := $cluster.owner | default "rancher" -}}
{{- $dbName := $cluster.database | default "rancher" -}}
apiVersion: v1
kind: Secret
metadata:
  name: rancher-db-credentials
  namespace: {{ $clusterNS }}
type: Opaque
stringData:
  username: {{ $owner }}
  password: {{ $cnpg.password }}
  host: {{ $clusterName }}-rw.{{ $clusterNS }}
  port: "5432"
  dbname: {{ $dbName }}
{{- end -}}

{{- define "rke2-harvester.rancherHPA" -}}
{{- $hpa := .Values.rancherHPA | default (dict) -}}
{{- $metrics := $hpa.metrics | default (dict) -}}
{{- $cpu := $metrics.cpu | default (dict) -}}
{{- $mem := $metrics.memory | default (dict) -}}
{{- $rancherReleaseName := printf "%s-rancher" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- $rm := .Values.rancherManager | default (dict) -}}
{{- $rancherNS := $rm.namespace | default "cattle-system" -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $rancherReleaseName }}
  namespace: {{ $rancherNS }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $rancherReleaseName }}
  minReplicas: {{ $hpa.minReplicas | default 3 }}
  maxReplicas: {{ $hpa.maxReplicas | default 7 }}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ $cpu.averageUtilization | default 70 }}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: {{ $mem.averageUtilization | default 80 }}
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
{{- $poolName := $pool.name | default (printf "%s-pool-%d" $chartName (add $idx 1)) }}
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

{{- define "rke2-harvester.ciliumHelmChartConfig" -}}
{{- $cilium := .Values.cilium | default dict -}}
{{- $kubeVip := .Values.kubeVip | default dict -}}
{{- $extraValues := $cilium.values | default dict -}}
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |
    kubeProxyReplacement: true
    k8sServiceHost: {{ $kubeVip.address | default "127.0.0.1" | quote }}
    k8sServicePort: "6443"
    l2announcements:
      enabled: true
    externalIPs:
      enabled: true
{{- if $extraValues }}
{{ toYaml $extraValues | indent 4 }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.ciliumL2Resources" -}}
{{- $cilium := .Values.cilium | default dict -}}
{{- $l2 := $cilium.l2 | default dict -}}
{{- $pools := $l2.addressPools | default list -}}
{{- range $idx, $pool := $pools }}
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: {{ $pool.name | default (printf "pool-%d" (add $idx 1)) }}
spec:
  blocks:
{{- range $addr := $pool.addresses | default list }}
    - cidr: {{ $addr }}
{{- end }}
{{- if hasKey $pool "autoAssign" }}
  allowFirstLastIPs: {{ if $pool.autoAssign }}Yes{{ else }}No{{ end }}
{{- end }}
{{- if and (hasKey $pool "autoAssign") (not $pool.autoAssign) }}
  serviceSelector:
    matchLabels:
      cilium.io/pool: {{ $pool.name }}
{{- end }}
{{- end }}
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: l2-default
spec:
  loadBalancerIPs: true
  externalIPs: true
  interfaces:
    - ^eth[0-9]+
{{- end -}}

{{- define "rke2-harvester.traefikValues" -}}
{{- $traefik := .Values.traefik | default (dict) -}}
{{- $svc := $traefik.service | default (dict) -}}
{{- $extraValues := $traefik.values | default (dict) -}}
providers:
  kubernetesGateway:
    enabled: true
    experimentalChannel: true
  kubernetesIngress:
    enabled: true
gateway:
  enabled: false
service:
  type: {{ $svc.type | default "LoadBalancer" }}
{{- if $svc.loadBalancerIP }}
  spec:
    loadBalancerIP: {{ $svc.loadBalancerIP | quote }}
{{- end }}
{{- if $svc.annotations }}
  annotations:
{{ toYaml $svc.annotations | indent 4 }}
{{- end }}
{{- if $extraValues }}
{{ toYaml $extraValues }}
{{- end }}
{{- end -}}

{{- define "rke2-harvester.traefikHelmChart" -}}
{{- $traefik := .Values.traefik | default (dict) -}}
{{- $helmNS := $traefik.helmChartNamespace | default "kube-system" -}}
{{- $targetNS := $traefik.namespace | default "traefik-system" -}}
{{- $repo := $traefik.chartRepo | default "https://traefik.github.io/charts" -}}
{{- $chart := $traefik.chartName | default "traefik" -}}
{{- $releaseName := printf "%s-traefik" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: {{ $releaseName }}
  namespace: {{ $helmNS }}
spec:
  chart: {{ $chart }}
  repo: {{ $repo | quote }}
  targetNamespace: {{ $targetNS }}
  createNamespace: true
{{- if $traefik.chartVersion }}
  version: {{ $traefik.chartVersion | quote }}
{{- end }}
  valuesContent: |
{{ include "rke2-harvester.traefikValues" . | indent 4 }}
{{- end -}}

{{- define "rke2-harvester.gatewayAPICRDJob" -}}
{{- $gw := .Values.gatewayAPI | default dict -}}
{{- $version := $gw.crdVersion | default "v1.2.1" -}}
{{- $crdUrl := $gw.crdUrl | default (printf "https://github.com/kubernetes-sigs/gateway-api/releases/download/%s/standard-install.yaml" $version) -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: install-gateway-api-crds
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: install-gateway-api-crds
rules:
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["validatingwebhookconfigurations"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: install-gateway-api-crds
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: install-gateway-api-crds
subjects:
  - kind: ServiceAccount
    name: install-gateway-api-crds
    namespace: kube-system
---
apiVersion: batch/v1
kind: Job
metadata:
  name: install-gateway-api-crds
  namespace: kube-system
spec:
  backoffLimit: 10
  template:
    spec:
      serviceAccountName: install-gateway-api-crds
      restartPolicy: OnFailure
      containers:
        - name: install
          image: {{ .Values.vmDeployment.image | default "alpine/kubectl:1.34.2" }}
          command:
            - sh
            - -c
            - |
              kubectl apply -f {{ $crdUrl }}
{{- end -}}

{{- define "rke2-harvester.rancherGateway" -}}
{{- $gw := .Values.gatewayAPI | default dict -}}
{{- $gwCfg := $gw.gateway | default dict -}}
{{- $rm := .Values.rancherManager | default dict -}}
{{- $rancherNS := $rm.namespace | default "cattle-system" -}}
{{- $gwName := $gwCfg.name | default "rancher-gateway" -}}
{{- $hostname := $gwCfg.hostname | default ($rm.hostname | default "") -}}
{{- $issuerName := $gwCfg.certIssuerName | default "" -}}
{{- $issuerKind := $gwCfg.certIssuerKind | default "ClusterIssuer" -}}
{{- $rancherReleaseName := printf "%s-rancher" (include "rke2-harvester.fullname" .) | trunc 63 | trimSuffix "-" -}}
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ $gwName }}
  namespace: {{ $rancherNS }}
{{- if $issuerName }}
  annotations:
    cert-manager.io/issuer: {{ $issuerName }}
    cert-manager.io/issuer-kind: {{ $issuerKind }}
{{- end }}
spec:
  gatewayClassName: traefik
  listeners:
    - name: https
      protocol: HTTPS
      port: {{ $gwCfg.listenerPort | default 443 }}
{{- if $hostname }}
      hostname: {{ $hostname | quote }}
{{- end }}
      tls:
        mode: Terminate
        certificateRefs:
          - name: {{ $gwName }}-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rancher
  namespace: {{ $rancherNS }}
spec:
  parentRefs:
    - name: {{ $gwName }}
      sectionName: https
{{- if $hostname }}
  hostnames:
    - {{ $hostname | quote }}
{{- end }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ $rancherReleaseName }}
          port: 443
{{- end -}}

{{- define "rke2-harvester.kubeVipStaticManifest" -}}
{{- $airgapKV := (.Values.airgap).images | default dict -}}
{{- $vip := .Values.kubeVip -}}
{{- $namespace := default "kube-system" $vip.namespace -}}
{{- $defaultSA := printf "%s-kube-vip" (include "rke2-harvester.fullname" .) -}}
{{- $serviceAccount := default $defaultSA $vip.serviceAccountName -}}
{{- $cidr := $vip.cidr | default "" -}}
{{- $interface := $vip.interface | default "eth0" -}}
{{- $vipCidr := (printf "%v" ($cidr | default "")) -}}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip
  namespace: {{ $namespace }}
  labels:
    app.kubernetes.io/name: kube-vip
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-vip
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-vip
    spec:
      serviceAccountName: {{ $serviceAccount }}
      automountServiceAccountToken: true
      hostNetwork: true
      priorityClassName: system-node-critical
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - operator: Exists
      initContainers:
        - name: sysctl-promote-secondaries
          image: {{ $airgapKV.busybox | default "busybox:1.36" }}
          securityContext:
            privileged: true
          command:
            - sh
            - -c
            - >
              sysctl -w net.ipv4.conf.all.promote_secondaries=1 net.ipv4.conf.{{ $interface }}.promote_secondaries=1
              net.ipv4.conf.all.accept_local=1 net.ipv4.conf.{{ $interface }}.accept_local=1
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
            - name: lb_enable
              value: "false"
            - name: vip_interface
              value: {{ $interface }}
            - name: vip_address
              value: {{ $vip.address | quote }}
            - name: vip_leaderelection
              value: "true"
            - name: cp_namespace
              value: kube-system
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
          lifecycle:
            postStart:
              exec:
                command:
                  - sh
                  - -c
                  - >
                    ip addr add {{ $vip.address }}{{ if $vipCidr }}/{{ $vipCidr }}{{ end }} dev {{ $interface }} 2>/dev/null || true
{{- end -}}

{{- define "rke2-harvester.userData" -}}
{{- $airgap := .Values.airgap | default dict -}}
{{- $airgapImages := $airgap.images | default dict -}}
{{- $airgapRegistries := $airgap.registries | default dict -}}
{{- $airgapYumRepos := $airgap.yumRepos | default dict -}}
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
{{- if (.Values.traefik).enabled }}
        - rke2-ingress-nginx
{{- end }}
      node-label:
        - harvesterhci.io/managed=true
      token: "{{ .Values.rke2.token }}"
      cni:
        - {{ .Values.rke2.cni }}
      cloud-provider-name: harvester
{{- if $airgap.systemDefaultRegistry }}
      system-default-registry: {{ $airgap.systemDefaultRegistry | quote }}
{{- end }}
{{- $kubeVip := .Values.kubeVip | default dict -}}
{{- $hasVipAddress := $kubeVip.address -}}
{{- $hasVip := and ($kubeVip.enabled | default false) $kubeVip.address }}
{{- $useDaemonSet := $kubeVip.useDaemonSet | default true -}}
{{- $vipRBAC := and $hasVip ($kubeVip.rbac.create | default true) }}
{{- if $hasVipAddress }}
      server: https://{{ $kubeVip.address }}:9345
{{- end }}
{{- if or $hasVipAddress (gt (len .Values.tlsSANs) 0) }}
      tls-san:
{{- if $hasVipAddress }}
        - {{ $kubeVip.address }}
{{- end }}
{{- range .Values.tlsSANs }}
        - {{ . }}
{{- end }}
{{- end }}
{{- if and $hasVip $vipRBAC }}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip-rbac.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.kubeVipRBACManifest" . | indent 6 }}
{{- end }}
{{- if and $hasVip $useDaemonSet }}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.kubeVipStaticManifest" . | indent 6 }}
{{- end }}
{{- if $hasVipAddress }}
  - path: /var/lib/rancher/rke2/server/manifests/harvester-cloud-provider-config.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChartConfig
      metadata:
        name: harvester-cloud-provider
        namespace: kube-system
      spec:
        valuesContent: |
          kube-vip:
            enabled: true
            image:
              repository: {{ $kubeVip.imageRepository | default "ghcr.io/kube-vip/kube-vip" }}
              tag: {{ $kubeVip.imageTag | default "v1.0.4" | quote }}
            config:
              address: {{ $kubeVip.address | quote }}
            tolerations:
              - operator: Exists
            env:
              vip_interface: {{ ($kubeVip.interface | default "eth0") | quote }}
              vip_arp: "true"
              lb_enable: "false"
              lb_port: "6443"
              vip_cidr: {{ $kubeVip.vip_subnet | default "24" | quote }}
              vip_subnet: {{ $kubeVip.vip_subnet | default "24" | quote }}
              cp_enable: "true"
              svc_enable: "false"
              vip_leaderelection: "true"
              enable_service_security: "false"
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
{{- $cpAllowWorkloads := default true .Values.controlPlane.allowWorkloads -}}
{{- $ciliumEnabled := (.Values.cilium).enabled | default false -}}
{{- $ciliumL2Enabled := and $ciliumEnabled ((.Values.cilium).l2).enabled | default false -}}
{{- $traefikEnabled := (.Values.traefik).enabled | default false -}}
{{- $traefikNamespace := (.Values.traefik).namespace | default "traefik-system" -}}
{{- $gwAPIEnabled := (.Values.gatewayAPI).enabled | default false -}}
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
{{- $cnpgEnabled := (.Values.cloudNativePG).enabled | default false -}}
{{- if $cnpgEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/cnpg-namespace.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: {{ (.Values.cloudNativePG).namespace | default "cnpg-system" }}
{{- end }}
{{- if $cnpgEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/cnpg-operator.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.cnpgHelmChart" . | indent 6 }}
{{- end }}
{{- if $cnpgEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/zz-cnpg-cluster.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.cnpgCluster" . | indent 6 }}
{{- end }}
{{- if and $cnpgEnabled (.Values.cloudNativePG).password }}
  - path: /var/lib/rancher/rke2/server/manifests/zz-rancher-db-secret.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.rancherDBSecret" . | indent 6 }}
{{- end }}
{{- if and (.Values.rancherHPA).enabled $cnpgEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/zz-rancher-hpa.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.rancherHPA" . | indent 6 }}
{{- end }}
{{- $cloudProvider := .Values.cloudProvider | default (dict) -}}
{{- if $cloudProvider.cloudConfig }}
  - path: {{ $cloudProvider.configPath | default "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config" }}
    owner: root:root
    permissions: "0644"
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
{{- if $ciliumEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/cilium-config.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.ciliumHelmChartConfig" . | indent 6 }}
{{- end }}
{{- if $ciliumL2Enabled }}
  - path: /var/lib/rancher/rke2/server/manifests/zz-cilium-l2.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.ciliumL2Resources" . | indent 6 }}
{{- end }}
{{- if $gwAPIEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/00-gateway-api-crds.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.gatewayAPICRDJob" . | indent 6 }}
{{- end }}
{{- if and $traefikEnabled $traefikNamespace }}
  - path: /var/lib/rancher/rke2/server/manifests/traefik-namespace.yaml
    owner: root:root
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: {{ $traefikNamespace }}
{{- end }}
{{- if $traefikEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/traefik.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.traefikHelmChart" . | indent 6 }}
{{- end }}
{{- if and $gwAPIEnabled $rancherEnabled }}
  - path: /var/lib/rancher/rke2/server/manifests/zz-rancher-gateway.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{ include "rke2-harvester.rancherGateway" . | indent 6 }}
{{- end }}
{{- if $airgap.privateCA }}
  - path: /etc/pki/ca-trust/source/anchors/private-ca.crt
    owner: root:root
    permissions: "0644"
    content: |
{{ $airgap.privateCA | indent 6 }}
  - path: /etc/rancher/rke2/certs/private-ca.crt
    owner: root:root
    permissions: "0644"
    content: |
{{ $airgap.privateCA | indent 6 }}
{{- end }}
{{- if or $airgapRegistries.mirrors $airgapRegistries.configs }}
{{- $mergedConfigs := dict -}}
{{- range $regHost, $regCfg := ($airgapRegistries.configs | default dict) }}
{{- $tlsCfg := $regCfg.tls | default dict -}}
{{- if and $airgap.privateCA (not (hasKey $tlsCfg "ca_file")) }}
{{- $newTls := merge (dict "ca_file" "/etc/rancher/rke2/certs/private-ca.crt") $tlsCfg -}}
{{- $newCfg := merge (dict "tls" $newTls) $regCfg -}}
{{- $_ := set $mergedConfigs $regHost $newCfg -}}
{{- else }}
{{- $_ := set $mergedConfigs $regHost $regCfg -}}
{{- end }}
{{- end }}
  - path: /etc/rancher/rke2/registries.yaml
    owner: root:root
    permissions: "0644"
    content: |
{{- if $airgapRegistries.mirrors }}
      mirrors:
{{ toYaml $airgapRegistries.mirrors | indent 8 }}
{{- end }}
{{- if gt (len $mergedConfigs) 0 }}
      configs:
{{ toYaml $mergedConfigs | indent 8 }}
{{- end }}
{{- end }}
{{- range $repoId, $repo := $airgapYumRepos }}
  - path: /etc/yum.repos.d/{{ $repoId }}.repo
    owner: root:root
    permissions: "0644"
    content: |
      [{{ $repoId }}]
      name={{ $repo.name | default $repoId }}
      baseurl={{ $repo.baseurl }}
      enabled={{ if hasKey $repo "enabled" }}{{ if $repo.enabled }}1{{ else }}0{{ end }}{{ else }}1{{ end }}
      gpgcheck={{ if hasKey $repo "gpgcheck" }}{{ if $repo.gpgcheck }}1{{ else }}0{{ end }}{{ else }}0{{ end }}
{{- if $repo.gpgkey }}
      gpgkey={{ $repo.gpgkey }}
{{- end }}
{{- end }}
chpasswd:
  list: |
    {{ .Values.ssh.user }}:{{ .Values.ssh.password | default "rocky2025" }}
  expire: false
runcmd:
{{- if $airgap.privateCA }}
  - update-ca-trust force-enable && update-ca-trust extract
{{- end }}
{{- if $airgap.disableDefaultRepos }}
  - "sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/rocky*.repo || true"
{{- end }}
  - systemctl enable --now qemu-guest-agent.service
  - |
    set -euo pipefail
    HOSTNAME="$(hostname)"
    INSTALL_TYPE="server"
    SERVICE="rke2-server"
    if echo "${HOSTNAME}" | grep -q -- "-cp-1$"; then
      sed -i '/^server:/d' /etc/rancher/rke2/config.yaml
      sed -i '/^cluster-init:/d' /etc/rancher/rke2/config.yaml
      echo "cluster-init: true" >> /etc/rancher/rke2/config.yaml
    fi
    if echo "${HOSTNAME}" | grep -q -- "-wk-"; then
      INSTALL_TYPE="agent"
      SERVICE="rke2-agent"
      sed -i '/^cluster-init:/d' /etc/rancher/rke2/config.yaml
    fi
{{- $installUrl := $airgap.rke2InstallUrl | default "https://get.rke2.io" }}
{{- $installMethod := $airgap.rke2InstallMethod | default "" }}
{{- $artifactPath := $airgap.rke2ArtifactPath | default "" }}
    curl -sfL {{ $installUrl }} | \
      INSTALL_RKE2_TYPE=${INSTALL_TYPE} \
{{- if .Values.rke2.version }}
      INSTALL_RKE2_VERSION={{ .Values.rke2.version | quote }} \
{{- end }}
{{- if $installMethod }}
      INSTALL_RKE2_METHOD={{ $installMethod }} \
{{- end }}
{{- if $artifactPath }}
      INSTALL_RKE2_ARTIFACT_PATH={{ $artifactPath }} \
{{- end }}
      sh -
    systemctl enable ${SERVICE}.service
    systemctl start ${SERVICE}.service || true
    # Wait for RKE2 to become healthy (Type=notify timeout is expected on first boot)
    for i in $(seq 1 60); do
      if systemctl is-active --quiet ${SERVICE}.service; then
        break
      fi
      sleep 10
    done
{{- if $cloudProvider.cloudConfig }}
    # Wait for RKE2 to initialize directory structure, then fix SELinux context
    # so containers with container_t domain can read the cloud-provider-config.
    for i in $(seq 1 30); do
      if [ -f {{ $cloudProvider.configPath | default "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config" | quote }} ]; then
        chcon -t container_file_t {{ $cloudProvider.configPath | default "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config" | quote }}
        break
      fi
      sleep 2
    done
{{- end }}
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
  - |
    cat <<'EOF' >/usr/local/bin/manage-controlplane-taint.sh
    #!/bin/bash
    set -euo pipefail
    HOSTNAME="$(hostname)"
    case "${HOSTNAME}" in
      *-cp-*) ;;
      *) exit 0 ;;
    esac
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    TARGET_TAINT="node-role.kubernetes.io/control-plane=:NoSchedule"
    for i in {1..60}; do
      if kubectl get nodes >/dev/null 2>&1; then
{{- if $cpAllowWorkloads }}
        kubectl taint nodes "$HOSTNAME" "${TARGET_TAINT}"- || true
{{- else }}
        kubectl taint nodes "$HOSTNAME" "${TARGET_TAINT}" --overwrite || true
{{- end }}
        exit 0
      fi
      sleep 5
    done
    exit 0
    EOF
    chmod +x /usr/local/bin/manage-controlplane-taint.sh
    /usr/local/bin/manage-controlplane-taint.sh &
  - |
    cat <<'EOF' >/usr/local/bin/label-worker.sh
    #!/bin/bash
    set -euo pipefail
    HOSTNAME="$(hostname)"
    case "${HOSTNAME}" in
      *-wk-*) ;;
      *) exit 0 ;;
    esac
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    for i in {1..60}; do
      if kubectl get nodes >/dev/null 2>&1; then
        kubectl label nodes "$HOSTNAME" worker=true role=worker --overwrite || true
        exit 0
      fi
      sleep 5
    done
    exit 0
    EOF
    chmod +x /usr/local/bin/label-worker.sh
    /usr/local/bin/label-worker.sh &
{{- end -}}
