# Step-CA Helm Chart

This Helm chart deploys a Step-CA server on a virtual machine within a Harvester cluster.

## Prerequisites

- A running Harvester cluster (v1.1.0 or higher).
- A pre-existing VM image in Harvester. The image should be a cloud image that supports cloud-init (e.g., Rocky Linux 9 Cloud Image).
- A pre-existing network in Harvester for the VM to connect to.
- `kubectl` configured to access the Harvester cluster.
- `helm` v3 or higher.

## Chart Description

This chart will:
1.  Create a `PersistentVolumeClaim` for the VM's root disk, using a specified Harvester `VirtualMachineImage`.
2.  Create a `Secret` containing a `cloud-init` script to configure the VM.
3.  Deploy a `VirtualMachine` instance on Harvester.

The `cloud-init` script will:
- Create a user and set up SSH access.
- Download and install the `step` CLI and `step-ca` server binaries.
- Initialize the Step Certificate Authority using the provided configuration.
- Set up and start a `systemd` service to run `step-ca`.

## Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd <repository-directory>/charts
    ```

2.  **Customize the values:**
    Update the `step-ca/values.yaml` file with your desired configuration. You must provide your SSH public key.

3.  **Install the chart:**
    ```bash
    helm install my-step-ca ./step-ca --namespace default
    ```
    Replace `my-step-ca` with your desired release name and `default` with the target namespace.

## Configuration

The following table lists the configurable parameters of the `step-ca` chart and their default values.

| Parameter                      | Description                                                              | Default                                |
| ------------------------------ | ------------------------------------------------------------------------ | -------------------------------------- |
| `vm.name`                      | Name of the virtual machine.                                             | `step-ca`                              |
| `vm.namespace`                 | Namespace to deploy the VM in.                                           | `default`                              |
| `vm.image.namespace`           | Namespace of the source VM image.                                        | `harvester-public`                     |
| `vm.image.name`                | Name of the source VM image.                                             | `rocky-9-cloudimg`                     |
| `vm.cpu`                       | Number of CPU cores for the VM.                                          | `2`                                    |
| `vm.memory`                    | Amount of memory for the VM.                                             | `4Gi`                                  |
| `vm.disk.size`                 | Size of the VM's root disk.                                              | `20Gi`                                 |
| `vm.disk.storageClassName`     | StorageClass for the root disk.                                          | `harvester-longhorn`                   |
| `vm.network.name`              | Name of the Harvester network to connect the VM to.                      | `vlan2003`                             |
| `ssh.user`                     | SSH username for the VM.                                                 | `rocky`                                |
| `ssh.publicKey`                | SSH public key for accessing the VM.                                     | `""` (Must be provided)                |
| `stepCa.name`                  | The name of the certificate authority.                                   | `"Aegis Group Internal CA"`            |
| `stepCa.address`               | The address for the CA server to listen on.                              | `":9000"`                              |
| `stepCa.dns`                   | DNS name for the CA.                                                     | `"ca.aegisgroup.ch"`                   |
| `stepCa.provisioner.name`      | Name of the initial provisioner.                                         | `admin`                                |
| `stepCa.provisioner.password`  | Password for the initial provisioner.                                    | `"password"`                           |
| `stepCa.password`              | Password for the CA's encryption keys.                                   | `"password"`                           |
| `versions.stepCli`             | Version of the `step` CLI to install.                                    | `"0.26.1"`                             |
| `versions.stepCa`              | Version of the `step-ca` server to install.                              | `"0.26.1"`                             |
| `service.type`                 | Type of Kubernetes service to expose the CA.                             | `LoadBalancer`                         |
| `service.port`                 | Port for the service.                                                    | `9000`                                 |
| `ingress.enabled`              | Enable an Ingress resource for the CA.                                   | `true`                                 |
| `ingress.hostname`             | Hostname for the Ingress.                                                | `ca.aegisgroup.ch`                     |
| `ingress.tls`                  | Enable TLS for the Ingress.                                              | `true`                                 |
| `ingress.secretName`           | Name of the TLS secret for the Ingress.                                  | `ca-tls`                               |