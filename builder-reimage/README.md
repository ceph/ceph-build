# Builder Reimage Pipeline

## Overview

This pipeline is used to reimage Jenkins builder nodes and then perform post-reimage configuration using Ansible.

It supports one or more target nodes and can process multiple nodes in parallel. The pipeline derives the target operating system from builder labels defined in the `ceph-sepia-secrets` inventory instead of relying on manually supplied OS input. After reimage, it prepares the execution environment, clones the required repositories, and runs a sequence of Ansible playbooks to configure the builder.

The pipeline is designed so that it can be reproduced with the correct Jenkins configuration, required credentials, repository access, and workspace dependencies.

---

## Purpose

The pipeline is responsible for the following:

- reimage one or more Jenkins builder nodes using the MaaS-based reimage utility
- detect the target OS from the source-of-truth inventory labels
- prepare workspace-local dependencies
- clone or update the required repositories
- run post-reimage Ansible playbooks
- support parallel execution for multiple nodes
- capture and archive Ansible logs for troubleshooting

---

## Source of truth for OS detection

The operating system is not passed manually as a Jenkins parameter.

Instead, the pipeline reads:

```text
ceph-sepia-secrets/ansible/inventory/group_vars/jenkins_builders.yml
```
From that file, it reads the `jenkins_labels` mapping and extracts:

- `installed-os-*` to determine the target operating system
- Optional feature labels such as libvirt

Example label string:
```
braggi noble small huge sepia x86_64 installed-os-noble libvirt
```
From the above, the pipeline derives:

- OS = noble
- libvirt = true

## High level workflow
For each node provided in the MACHINE parameter, the pipeline performs the following steps:

1. Checkout the repository containing the pipeline and helper scripts
2. Prepare the node-specific workspace and execution environment
3. Clone or update the required repositories
4. Read the builder inventory file and detect the OS and feature labels
5. Reimage the node using the detected OS
6. Run post-reimage Ansible playbooks
7. Archive node-specific Ansible logs

If multiple nodes are passed, each node is processed in parallel.

## Jenkins job parameters

### ***MACHINE***
Comma-separated list of target builder short names.

Examples:
```
braggi01
braggi01,braggi16
```

### ***ACTION***
Supported values:
- reimage
- reimage-all
- wait_online

Current execution primarily uses the reimage flow.

### ***SKIP_REIMAGE***

If set to true, the MaaS reimage step is skipped and only the post-reimage Ansible tasks are run.

## Pipeline configuration

***Jenkins pipeline***
```
builder-reimage/build/Jenkinsfile
```
Defines the pipeline stages, parallel execution, OS detection, reimage, Ansible execution, and log archiving.

***Environment preparation***

```
builder-reimage/build/prepare_env.sh
```
Clones or updates required repositories, creates the virtual environment, installs Ansible if needed, and prepares workspace-local Ansible configuration.

***Ansible runner***
```
builder-reimage/build/ansible_runner.sh
```
Runs the post-reimage Ansible playbooks, handles retries, writes logs, and prints the final execution summary.

***OS and feature detection***
```
builder-reimage/build/get_node_os.py
```
Reads jenkins_builders.yml and extracts the installed OS and relevant labels such as libvirt.

***Reimage utility***
```
builder-reimage/build/Jenkins_builder-reimage.py
```
Performs the MaaS-based release and deploy operations.

## Jenkins credentials used

The pipeline depends on the following Jenkins credentials.

### ***maas-api-key***
Used by the reimage utility to interact with MaaS.

### ***builder-api-token***
Passed to the builder playbook.

### ***ansible-vault-pass***
Used to unlock Ansible Vault protected data.

### ***ansible-ssh-key***
Used to clone and update private Git repositories over SSH.

## Required repositories
The pipeline uses these repositories:

```
git@github.com:ceph/ceph-build.git
git@github.com:ceph/ceph-cm-ansible.git
git@github.com:ceph/ceph-sepia-secrets.git
```

## Ansible playbooks executed
The pipeline currently runs these playbooks in order:

```
ansible_managed.yml
users.yml
tools/jenkins-builder-disk.yml
examples/builder.yml
```

ansible_runner.sh retries each playbook up to three times and prints a final summary at the end.

## Reproducing this pipeline
To reproduce this pipeline, the following are required:

- Jenkins pipeline job configured with the JJB definition `builder-reimage/config/definitions/builder-reimage.yml`
- Jenkins agent with the teuthology label
- Jenkins credentials:

  - maas-api-key
  - builder-api-token
  - ansible-vault-pass
  - ansible-ssh-key


- access to the required GitHub repositories
- access to MaaS
- Python 3, virtual environment support, Git, SSH, and Ansible installation capability on the Jenkins agent

## Notes

- OS selection is inventory-driven and no longer passed manually.
- The pipeline supports parallel execution for multiple nodes.
- Logs are written under ci-work-<node>/ansible-logs/ and archived by Jenkins.
- Optional labels such as libvirt can be passed through to Ansible when needed.
=======
# Builder Reimage

Builder Reimage is a lightweight automation utility for interacting with **MAAS (Metal as a Service)**.  
It allows you to list, query, check status, and redeploy machines efficiently, with or without specifying an operating system.

This script simplifies MAAS machine management tasks and helps maintain consistent environment setups through a command-line interface.

---

## Features
- List all managed MAAS machines  
- Query machine details  
- Check deployment or power status  
- Redeploy single or multiple machines  
- Redeploy with or without specifying an OS version  

---

## Requirements
- Python 3.8 or higher  
- MAAS CLI installed and configured  
- Valid MAAS API credentials

---

## Cloning the Repository

To get started, clone the repository and navigate into the project directory:

```bash
git clone https://github.com/jitendrasahu1803/builder-reimage.git

cd builder-reimage
```

## Setup your environment to use the tool

Run bootstrap script:
```bash
bash bootstrap_env.sh
```
Active your virtual environment:
```bash
source .venv/bin/activate
```
Edit ```bash maas.conf``` file and update it with the correct MAAS URL (Sepia/Tucson):
```bash
cat maas.conf
[maas]
maas_url=http://<Enter_MAAS_URL>/MAAS
```
To setup your credential to connect with MAAS API, run (Replace <YOUR_MAAS_API_KEY> with your actual MAAS API key):
```bash
echo -n "<YOUR_MAAS_API_KEY>" | python3 -c 'import sys; from cryptography.fernet import Fernet; key=Fernet.generate_key(); open("maas_api.key","wb").write(key); data=sys.stdin.buffer.read(); open("maas_api_key.encrypted","wb").write(Fernet(key).encrypt(data)); print("wrote: maas_api.key and maas_api_key.encrypted")'
```
---

## Usage
Activate your virtual environment (if not already active), then run:
```bash
python3 maas-reimage.py [OPTIONS]
```

## Examples
List all machines
```bash
--action list
```
Query details for one machine
```bash
--action query --machine node01
```
Check machine status
```bash
--action status --machine node01
```
Deploy a machine with a specific OS:
```bash
--action deploy --machine node01 --os 9.6
```
Reimage one machine (same OS)
```bash
--action reimage --machine node01
```
Reimage one machine with a specific OS
```bash
--action reimage --machine node01 --os jammy
```
Redeploy all machines
```bash
--action reimage-all
```
Redeploy all machines with a specific OS
```bash
--action reimage-all --os jammy
```
Find last deployed machine
```bash
--action last-deployed
```

## Additional option of (--owner)

When you deploy or reimage a machine, it is automatically tagged with the default owner ```jitendra```. If you want to assign a different owner, you can specify it using the option shown below.

Reimage a machine with a custom owner tag:
```bash
--action reimage --machine node01 --owner "<owner_name>"
```

This option works for deploy, reimage, reimage_all, and all other relevant commands.

---

## Author

Jitendra Sahu

GitHub: jitendrasahu1803

## License

This project is licensed under the MIT License.
