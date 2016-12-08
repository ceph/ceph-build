private-registry
================

Ansible playbook for deploying a self-signed private docker registry container.

## What does it do?

This playbook will generate a self-signed cert and start a private docker
registry container using that cert.  This private docker registry can then
be used by any client that has the cert.

This directory also includes vagrant files that will spin up two VMs and then
run the ansible playbook to provision one as a private docker registry and the
other as a test client to validate that it can use the self-signed cert to 
push an image to the private docker registry on the other node.

## Running Vagrant to Provision and Test

* Edit vagrant_variables.yml and change the `vagrant_box` variable if needed
* Use `vagrant up` command to deploy and provision the VMs

When the playbook completes successfully, it will have started the private
docker registry container and used the other VM to test pushing a test image
to that private docker container.

## Running the playbook against an existing machine

When you are ready to provision onto an existing machine, first make sure
that docker is installed on that machine.

In the top directory of this playbook where the `site.yml` file exist, add
an `ansible-hosts` file to specify the machine you want to provision.  It
should look something like this:

```
---
[registry]
ceph-docker-registry ansible_host=xx.xx.xx.xx ansible_port=2222 ansible_user=ubuntu
```

Once this is specified, you are ready to run the playbook with:

```
ansible-playbook -i ansible-hosts site.yml
```

Once the playbook is complete you can go out to your machine and do a 
`sudo docker ps` to see the private registry container running.

Any other docker client machine can now push to or pull from this private
registry if it has the self-signed cert in its docker certs directory.  To 
enable this on another machine:

* Create the directory on the client machine to hold the cert

```
$ sudo mkdir /etc/docker/certs.d/XX.XX.XX.XX\:5000
```

where `XX.XX.XX.XX` is the ip address of your private registry machine

* Copy the self-signed certificate from the private registry machine and place the cert in the newly created directory

```
$ scp XX.XX.XX.XX:/var/registry/certs/self.crt /etc/docker/certs.d/XX.XX.XX.XX\:5000/ca.crt
```

where `XX.XX.XX.XX` is the ip address of your private registry machine

Now you should be able to push images to and pull images from your private docker registry.

* To tag an image before pushing it to the private docker registry

```
$ docker tag myimage XX.XX.XX.XX\:5000/myimage
```

* To push the tagged image to the private docker registry
```
$ docker push XX.XX.XX.XX\:5000/myimage
```

* To pull an image from the private docker registry
```
$ docker pull XX.XX.XX.XX\:5000/someimage
```
