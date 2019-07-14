# High Availability Kubernetes with Kubeadm

kubeadm을 이용해 고가용성 Kubernetes 클러스터를 생성하는 실습을 진행합니다.

* Vagrant 를 이용해 Virtual Machine 생성
* kubeadm 으로 Single Control-Plane Kubernetes 클러스터 구성
* High Availability Kubernetes 클러스터로 변경
* Kubernetes 클러스터 관리



# Environments

* Kubernetes: 1.14.4
* VM Nodes: 3 (2 GB, 2 CPUs) / 1 (1 GB, 1 CPUs)
* VM Guest OS: Ubuntu 18.04 (ubuntu/bionic64)



## Install Virtualbox

사용하는 운영체제에 맞는 패키지를 받아 설치합니다.

- https://www.virtualbox.org/wiki/Downloads

```bash
sudo apt install virtualbox
```



## Install Vagrant 

VM 을 생성할 때 사용할 `Vagrant` 프로그램을 아래 링크에서 운영체제에 맞는 패키지를 받아 설치합니다.

- https://www.vagrantup.com/downloads.html

```bash
sudo dpkg -i vagrant_2.2.5_x86_64.deb
```



## Download Vagrant Box Image

`Vagrant` 를 이용해 VM 을 생성할 때 사용할 `Box` 파일을 미리 받아 디스크에 저장해둡니다.

```bash
vagrant box add ubuntu/bionic64
```



## Download Hands-on Worksheet

Github 저장소에 실습에 사용할 파일들을 올려두었습니다. 저장소에 있는 파일을 사용하기 위해  `git clone` 명령을 사용합니다.

```bash
git clone https://github.com/chanshik/cloudnativedays-korea-2019.git
cd cloudnativedays-korea-2019
```



## VM Nodes and Network

실습에 사용할 VM 별 역할과 할당하는 자원 목록입니다.

| Node    | IP          | Role    | RAM (GB) | CPUs | Description                   |
| ------- | ----------- | ------- | -------- | ---- | ----------------------------- |
| node-1  | 10.10.1.2   | Master  | 2        | 2    |                               |
| node-2  | 10.10.1.3   | Master  | 2        | 2    |                               |
| node-3  | 10.10.1.4   | Master  | 2        | 2    |                               |
| node-gw | 10.10.1.254 | Gateway | 1        | 1    | 클러스터에서 사용하는 Gateway |

`node-gw` VM 은 각 노드에서 외부 네트워크와 연결할 때 사용합니다.



## Vagrantfile

VM 을 한번에 띄우면서 기본적인 초기화 작업을 진행하기 위해 미리 작성해둔 Vagrant 파일을 이용합니다. 실습에 사용하는 노트북 혹은 장비 사양에 맞춰서 VM RAM 크기와 CPU 수를 조정하는 것을 권장합니다.

이번 실습에서는 각 VM 에 2 GB 메모리와 2 CPU 를 할당하였습니다. `node-gw` VM 은 Gateway 역할을 수행하는데 필요한 만큼만 할당합니다.

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"
  config.vm.box_check_update = false
  node_subnet = "10.10.1"
  node_prefix = "node"
  node_memory = "2048"
  node_cpu = 2
  vm_num = 3

  k8s_version = "1.14.4"
  pkg_version = "1.14.4-00"

  port_forwarder_ip = "#{node_subnet}.254"

  config.vm.define "#{node_prefix}-gw" do |node|
    hostname = "#{node_prefix}-gw"
    hostip = port_forwarder_ip

    node.vm.hostname = hostname
    node.vm.network "private_network", ip: hostip

    node.vm.provider "virtualbox" do |vb|
      vb.name = "#{node_prefix}-gw"
      vb.gui = false
      vb.cpus = 1
      vb.memory = "1024"
    end

    node.vm.provision "shell", run: "always", inline: <<-SHELL
      sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
      sudo iptables -A FORWARD -s "#{node_subnet}".0/24 -i enp0s8 -o enp0s3 -m conntrack --ctstate NEW -j ACCEPT
      sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      sudo iptables -t nat -A POSTROUTING -o enp0s3 -j MASQUERADE
    SHELL
  end

  (1..vm_num).each do |i|
    config.vm.define "#{node_prefix}-#{i}" do |node|
      hostname = "#{node_prefix}-#{i}"
      hostip = "#{node_subnet}.#{i + 1}"

      node.vm.hostname = hostname
      node.vm.network "private_network", ip: hostip

      node.vm.provider "virtualbox" do |vb|
        vb.name = "#{node_prefix}-#{i}"
        vb.gui = false
        vb.cpus = node_cpu
        vb.memory = node_memory
      end

      node.vm.provision "bootstrap", type: "shell", preserve_order: true, inline: <<-SHELL
        sudo curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
        sudo bash -c 'cat << APT_EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
APT_EOF'
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository \
          "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

        sudo apt update
        sudo apt install -y jq apt-transport-https ca-certificates curl software-properties-common
        sudo apt install -y docker-ce=18.06.2~ce~3-0~ubuntu
        sudo bash -c 'cat > /etc/docker/daemon.json << DAEMON_EOF
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
DAEMON_EOF'
        sudo mkdir -p /etc/systemd/system/docker.service.d
        sudo systemctl daemon-reload
        sudo systemctl restart docker
        sudo systemctl enable docker.service

        sudo apt install -y kubelet="#{pkg_version}" kubeadm="#{pkg_version}" kubectl="#{pkg_version}"
        sudo usermod -aG docker vagrant

        sudo sed -i '/k8s/d' /etc/hosts
        echo "#{node_subnet}.#{i + 1} #{node_prefix}-#{i}" | sudo tee -a /etc/hosts
      SHELL

      node.vm.provision "init-forward", type: "shell", run: "always", inline: <<-SHELL
        sudo echo "      gateway4: #{port_forwarder_ip}" | sudo tee -a /etc/netplan/50-vagrant.yaml
        sudo netplan apply
SHELL
  
      if i == 1
        node.vm.provision "master", type: "shell", preserve_order: true, privileged: false, inline: <<-SHELL
          cat > $HOME/kubeadm-config.yaml <<-CONFIG_EOF
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: #{k8s_version}
controlPlaneEndpoint: "#{hostip}:6443"
CONFIG_EOF
SHELL
      else
        node.vm.provision "secondary", type: "shell", preserve_order: true, inline: <<-SHELL

        SHELL
      end
    end
  end
end
```



## Start VMs

Vagrantfile 을 이용해 실습에 사용할 VM 노드를 생성합니다.

```bash
vagrant up

Bringing machine 'node-gw' up with 'virtualbox' provider...
Bringing machine 'node-1' up with 'virtualbox' provider...
Bringing machine 'node-2' up with 'virtualbox' provider...
Bringing machine 'node-3' up with 'virtualbox' provider...
...
```



생성한 VM 에 접속하여 패키지가 제대로 설치되었는지 확인합니다. 정상적으로 설치되었다면 `kubeadm`, `kubelet`, `kubectl` 프로그램을 사용할 수 있습니다.

```bash
$ vagrant ssh node-1
Welcome to Ubuntu 18.04.2 LTS (GNU/Linux 4.15.0-54-generic x86_64)

  System load:  0.0               Users logged in:        0
  Usage of /:   16.2% of 9.63GB   IP address for enp0s3:  10.0.2.15
  Memory usage: 5%                IP address for enp0s8:  10.10.1.2
  Swap usage:   0%                IP address for docker0: 172.17.0.1
  Processes:    100
  ...
```

```bash
kubeadm version

kubeadm version: &version.Info{Major:"1", Minor:"14", GitVersion:"v1.14.3", GitCommit:"5e53fd6bc17c0dec8434817e69b04a25d8ae0ff0", GitTreeState:"clean", BuildDate:"2019-06-06T01:41:54Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
```



# Setup Single Control-Plane Cluster

## Check Environments

이번 실습에서는 컨테이너 런타임으로 `Docker` 를 사용합니다. 다른 런타임을 사용하고 싶다면 다음 공식 문서를 참고하여 원하는 런타임을 골라서 이용할 수 있습니다.

[Installing runtime](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-runtime)

제대로 설치되었는지 확인합니다.

```bash
docker version

Client:
 Version:           18.06.2-ce
 API version:       1.38
 Go version:        go1.10.3
 Git commit:        6d37f41
 Built:             Sun Feb 10 03:47:56 2019
 OS/Arch:           linux/amd64
 Experimental:      false

Server:
 Engine:
  Version:          18.06.2-ce
  API version:      1.38 (minimum version 1.12)
  Go version:       go1.10.3
  Git commit:       6d37f41
  Built:            Sun Feb 10 03:46:20 2019
  OS/Arch:          linux/amd64
  Experimental:     false
```

```bash
docker ps

CONTAINER ID     IMAGE     COMMAND     CREATED       STATUS        PORTS           NAMES

```



Kubernetes 클러스터를 생성할 때 사용할 설정 내용을 `kubeadm-config.yaml` 파일에 저장해두었습니다. 클러스터를 생성할 때 이 설정 파일을 이용합니다.

**kubeadm-config.yaml**

```yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: 1.14.3
controlPlaneEndpoint: "10.10.1.2:6443"
```



## Initialize Master Node

`kubeadm` 과 `kubeadm-config.yaml` 설정 파일을 이용해 클러스터를 생성합니다.

```bash
sudo kubeadm init --config kubeadm-config.yaml

[init] Using Kubernetes version: v1.14.3
[preflight] Running pre-flight checks
	[WARNING IsDockerSystemdCheck]: detected "cgroupfs" as the Docker cgroup driver. The recommended driver is "systemd". Please follow the guide at https://kubernetes.io/docs/setup/cri/
[preflight] Pulling images required for setting up a Kubernetes cluster
[preflight] This might take a minute or two, depending on the speed of your internet connection
[preflight] You can also perform this action in beforehand using 'kubeadm config images pull'
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Activating the kubelet service
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "front-proxy-ca" certificate and key
[certs] Generating "front-proxy-client" certificate and key
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [node-1 localhost] and IPs [10.10.1.2 127.0.0.1 ::1]
[certs] Generating "etcd/peer" certificate and key
[certs] etcd/peer serving cert is signed for DNS names [node-1 localhost] and IPs [10.10.1.2 127.0.0.1 ::1]
[certs] Generating "etcd/healthcheck-client" certificate and key
[certs] Generating "apiserver-etcd-client" certificate and key
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [node-1 kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 10.10.1.2 10.10.1.2]
...
[mark-control-plane] Marking the node node-1 as control-plane by adding the label "node-role.kubernetes.io/master=''"
[mark-control-plane] Marking the node node-1 as control-plane by adding the taints [node-role.kubernetes.io/master:NoSchedule]
[bootstrap-token] Using token: rq5lv3.sxw4t5oh4d9j1ije
[bootstrap-token] Configuring bootstrap tokens, cluster-info ConfigMap, RBAC Roles
[bootstrap-token] configured RBAC rules to allow Node Bootstrap tokens to post CSRs in order for nodes to get long term certificate credentials
[bootstrap-token] configured RBAC rules to allow the csrapprover controller automatically approve CSRs from a Node Bootstrap Token
[bootstrap-token] configured RBAC rules to allow certificate rotation for all node client certificates in the cluster
[bootstrap-token] creating the "cluster-info" ConfigMap in the "kube-public" namespace
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

You can now join any number of control-plane nodes by copying certificate authorities 
and service account keys on each node and then running the following as root:

  kubeadm join 10.10.1.2:6443 --token rq5lv3.sxw4t5oh4d9j1ije \
    --discovery-token-ca-cert-hash sha256:16261e2504cceaad6a4b4f141676dd299ee066bd0aedd2311ae78ab33e06d752 \
    --experimental-control-plane 	  

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.10.1.2:6443 --token rq5lv3.sxw4t5oh4d9j1ije \
    --discovery-token-ca-cert-hash sha256:16261e2504cceaad6a4b4f141676dd299ee066bd0aedd2311ae78ab33e06d752
```



`kubectl` 명령을 사용해 클러스터를 관리하기 위해서는 `/etc/kubernetes/admin.conf` 파일이 필요합니다. 이 파일을 `$HOME/.kube/config` 에 복사하고 읽기 권한을 주는 방법이 있습니다. 만약에 둘 이상의 클러스터를 관리하거나 다른 위치에 두고 싶다면, 파일을 복사하고 읽기 권한을 준 후에 `KUBECONFIG` 환경 변수에 해당 위치를 지정해주는 방법을 사용할 수 있습니다.

`kubeadm` 실행 결과에 나와있는 명령을 실행하면 `$HOME/.kube/config` 파일을 생성할 수 있습니다.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```



이제 `kubectl` 명령을 사용하여 클러스터 상태를 확인할 수 있습니다.

```bash
kubectl get nodes

NAME     STATUS     ROLES    AGE     VERSION
node-1   NotReady   master   2m14s   v1.14.3
```



## Install Network Addon

아직까지는 노드 가  `NotReady` 상태입니다. 클러스터 구축을 마무리하기 위해서는 Network Addon 을 설치하는 작업이 필요합니다. 아래 페이지에서 선택할 수 있는 다양한 Addon 을 확인할 수 있습니다.

[Installing Addons](https://kubernetes.io/docs/concepts/cluster-administration/addons/)  

이번 실습에서는 `Weave Net`  을 설치해 사용하겠습니다.

```bash
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

serviceaccount/weave-net created
clusterrole.rbac.authorization.k8s.io/weave-net created
clusterrolebinding.rbac.authorization.k8s.io/weave-net created
role.rbac.authorization.k8s.io/weave-net created
rolebinding.rbac.authorization.k8s.io/weave-net created
daemonset.extensions/weave-net created
```



컨테이너를 받아서 설치를 마무리하면 클러스터 상태가 바뀌는 것을 볼 수 있습니다.

```bash
kubectl get nodes

NAME     STATUS   ROLES    AGE   VERSION
node-1   Ready    master   20m   v1.14.3
```



# Setup Multiple Master Cluster

## Copy Certificate Files

`Master` 노드를 2대 더 추가하여 고가용성 클러스터를 구축하겠습니다.

먼저 `Master` 노드에서 사용하고 있는 인증서를 새로 추가할 노드에 복사하는 작업이 필요합니다. 만약에 처음부터 바로 `Master` 를 추가하는 경우라면 (1.14.x 기준)

```bash
sudo kubeadm init --config=kubeadm-config.yaml --experimental-upload-certs
```

명령어를 사용해 인증서 복사하는 작업을 초기화 과정에서 진행하는 것도 가능합니다.

> `Kubernetes` 1.15.x 버전에서는 `--upload-certs` 를 이용합니다.



여기에서는 인증서를 직접 복사하여 클러스터를 구성하는 방법으로 진행하겠습니다.

`Master` 노드를 추가하기 위해 복사해야하는 인증서는 다음과 같습니다.

| File Path                              |
| -------------------------------------- |
| /etc/kubernetes/pki/ca.crt             |
| /etc/kubernetes/pki/ca.key             |
| /etc/kubernetes/pki/sa.key             |
| /etc/kubernetes/pki/sa.pub             |
| /etc/kubernetes/pki/front-proxy-ca.crt |
| /etc/kubernetes/pki/front-proxy-ca.key |
| /etc/kubernetes/pki/etcd/ca.crt        |
| /etc/kubernetes/pki/etcd/ca.key        |



`node-1` 에서 `ssh` 로 접속할 때 사용할 `비밀키`/`공개키` 쌍을 생성하고  `node-2`, `node-3` 의  `root` 계정에 `공개키` 를 추가합니다.

```bash
ssh-keygen -t rsa

Generating public/private rsa key pair.
Enter file in which to save the key (/home/vagrant/.ssh/id_rsa): 
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
Your identification has been saved in /home/vagrant/.ssh/id_rsa.
Your public key has been saved in /home/vagrant/.ssh/id_rsa.pub.
The key fingerprint is:
SHA256:c1H3OH+EBo66QEjFBtFIv/WcoJApIjBxdRs02ySAMBs vagrant@node-1
The key's randomart image is:
+---[RSA 2048]----+
|Eo.+BXB .   o .  |
|.*...*+O   + o + |
|+ . =.= + o . = o|
|.. . o + = o . + |
|      + S =     o|
|       . +      .|
|        .        |
|                 |
|                 |
+----[SHA256]-----+
```



`node-1` 에서 생성한 공개키를 `node-2`, `node-3` 에 복사하는 작업을 각 노드에 접속해서 진행합니다.

```bash
cat .ssh/id_rsa.pub 

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDdny6wUeORvjgX8trAdOV6qEgDcpaTFom1tQY2WBm/sNTa6Gx5F7gsihzndW2YGDazWtXhIOW3oLiev5PMM/cKbkU2MgMgWvcK3GZ3krrT3+7zZEBU2zBfiU+8Y5Visk20GAZxvv/REsqcccDiTygufbCnqD5/6v4ZaSOvsVbnR3iIjSlGa2eeqiIYgvo4bS2dQUHW6bu2+wLI6sCzgVdJzsSatuEi9HHwR6lYOPgcBlzh9czgKtz+Tzj478kEE/J0YMbs9eTx+AaF8pq9XksF4Jfh5oIJOwiEhINzX2Ez7hI8RV1Zy+lpL57jmFlXFEDZg+TUjRY2VfHLMkJRklFf vagrant@node-1
```

`node-2`

```bash
vagrant ssh node-2
sudo su -
cat >> .ssh/authorized_keys 
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDdny6wUeORvjgX8trAdOV6qEgDcpaTFom1tQY2WBm/sNTa6Gx5F7gsihzndW2YGDazWtXhIOW3oLiev5PMM/cKbkU2MgMgWvcK3GZ3krrT3+7zZEBU2zBfiU+8Y5Visk20GAZxvv/REsqcccDiTygufbCnqD5/6v4ZaSOvsVbnR3iIjSlGa2eeqiIYgvo4bS2dQUHW6bu2+wLI6sCzgVdJzsSatuEi9HHwR6lYOPgcBlzh9czgKtz+Tzj478kEE/J0YMbs9eTx+AaF8pq9XksF4Jfh5oIJOwiEhINzX2Ez7hI8RV1Zy+lpL57jmFlXFEDZg+TUjRY2VfHLMkJRklFf vagrant@node-1
```

`node-3`

```bash
vagrant ssh node-3
sudo su -
cat >> .ssh/authorized_keys 
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDdny6wUeORvjgX8trAdOV6qEgDcpaTFom1tQY2WBm/sNTa6Gx5F7gsihzndW2YGDazWtXhIOW3oLiev5PMM/cKbkU2MgMgWvcK3GZ3krrT3+7zZEBU2zBfiU+8Y5Visk20GAZxvv/REsqcccDiTygufbCnqD5/6v4ZaSOvsVbnR3iIjSlGa2eeqiIYgvo4bS2dQUHW6bu2+wLI6sCzgVdJzsSatuEi9HHwR6lYOPgcBlzh9czgKtz+Tzj478kEE/J0YMbs9eTx+AaF8pq9XksF4Jfh5oIJOwiEhINzX2Ez7hI8RV1Zy+lpL57jmFlXFEDZg+TUjRY2VfHLMkJRklFf vagrant@node-1
```



`node-1` 에서 각 노드 `root` 계정으로 접속할 수 있는지 확인합니다.

```bash
ssh root@10.10.1.3

The authenticity of host '10.10.1.3 (10.10.1.3)' can't be established.
ECDSA key fingerprint is SHA256:mQ+gtihe7nQBfGYtdhApRGNtO9W70kmRxXb9u+uwKs8.
Are you sure you want to continue connecting (yes/no)? yes
Warning: Permanently added '10.10.1.3' (ECDSA) to the list of known hosts.
Welcome to Ubuntu 18.04.2 LTS (GNU/Linux 4.15.0-54-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage
 ...

root@node-2:~#
```

```bash
ssh root@10.10.1.4

The authenticity of host '10.10.1.4 (10.10.1.4)' can't be established.
ECDSA key fingerprint is SHA256:igI5UDwj9w34yi9SLLvBWCx2JX1UvpVhED9EXEgf9pE.
Are you sure you want to continue connecting (yes/no)? yes
Warning: Permanently added '10.10.1.4' (ECDSA) to the list of known hosts.
Welcome to Ubuntu 18.04.2 LTS (GNU/Linux 4.15.0-54-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage
 ...

root@node-3:~#
```



이제 스크립트를 작성해 각 노드에 인증서 파일을 복사합니다.

**copy-certificates.sh**

```bash
USER=root
PRIV_KEY=/home/vagrant/.ssh/id_rsa
CONTROL_PLANE_IPS="10.10.1.3 10.10.1.4"
for host in ${CONTROL_PLANE_IPS}; do
    scp -i $PRIV_KEY /etc/kubernetes/pki/ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/ca.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/sa.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/sa.pub "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/front-proxy-ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/front-proxy-ca.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.crt "${USER}"@$host:etcd-ca.crt
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.key "${USER}"@$host:etcd-ca.key
done
```



복사 스크립트를 실행하면 인증서 파일을 `scp` 명령으로 복사하는 것을 볼 수 있습니다.

```bash
sudo ./copy-certificates.sh 

ca.crt                                  100% 1025   419.2KB/s   00:00    
ca.key                                  100% 1679     1.3MB/s   00:00    
sa.key                                  100% 1679     1.9MB/s   00:00    
sa.pub                                  100%  451   197.2KB/s   00:00    
front-proxy-ca.crt                      100% 1038   473.6KB/s   00:00    
front-proxy-ca.key                      100% 1679     1.1MB/s   00:00    
ca.crt                                  100% 1017   883.7KB/s   00:00    
ca.key                                  100% 1675   836.7KB/s   00:00    
ca.crt                                  100% 1025   917.1KB/s   00:00    
ca.key                                  100% 1679     1.6MB/s   00:00    
sa.key                                  100% 1679   618.6KB/s   00:00    
sa.pub                                  100%  451   530.3KB/s   00:00    
front-proxy-ca.crt                      100% 1038   997.4KB/s   00:00    
front-proxy-ca.key                      100% 1679   756.5KB/s   00:00    
ca.crt                                  100% 1017     1.3MB/s   00:00    
ca.key                                  100% 1675   783.5KB/s   00:00
```



`node-2`, `node-3` 에서는 인증서 파일을 `/etc/kubernetes/pki` 디렉토리로 이동합니다.

**move-certificates.sh**

```bash
USER=root
mkdir -p /etc/kubernetes/pki/etcd
mv /${USER}/ca.crt /etc/kubernetes/pki/
mv /${USER}/ca.key /etc/kubernetes/pki/
mv /${USER}/sa.pub /etc/kubernetes/pki/
mv /${USER}/sa.key /etc/kubernetes/pki/
mv /${USER}/front-proxy-ca.crt /etc/kubernetes/pki/
mv /${USER}/front-proxy-ca.key /etc/kubernetes/pki/
mv /${USER}/etcd-ca.crt /etc/kubernetes/pki/etcd/ca.crt
mv /${USER}/etcd-ca.key /etc/kubernetes/pki/etcd/ca.key
```



각 노드에서 `move-certificates.sh` 파일을 실행합니다.

```bash
sudo ./move-certificates.sh
```



파일이 제대로 옮겨졌는지 확인해보겠습니다.

```bash
ls -al /etc/kubernetes/pki

total 36
drwxr-xr-x 3 root root 4096 Jul  7 08:15 .
drwxr-xr-x 4 root root 4096 Jul  7 08:15 ..
-rw-r--r-- 1 root root 1025 Jul  5 10:55 ca.crt
-rw------- 1 root root 1679 Jul  5 10:55 ca.key
drwxr-xr-x 2 root root 4096 Jul  7 08:15 etcd
-rw-r--r-- 1 root root 1038 Jul  5 10:55 front-proxy-ca.crt
-rw------- 1 root root 1679 Jul  5 10:55 front-proxy-ca.key
-rw------- 1 root root 1679 Jul  5 10:55 sa.key
-rw------- 1 root root  451 Jul  5 10:55 sa.pub
```



## Join Control Plane Nodes

인증서 복사 작업을 수행한 이후에 `Master` 노드를 추가하는 작업을 진행합니다.

`kubeadm token` 명령을 이용해 노드를 추가하는 데 사용할 토큰과 명령어를 생성합니다.

```bash
sudo kubeadm token create --print-join-command

kubeadm join 10.10.1.2:6443 --token fb8x4h.z6afmap8a757kojm --discovery-token-ca-cert-hash sha256:a062d83e9c49adad5403d12aa563bc72dc684ca09a822c511aa299103e2b5d72
```



`kubeadm token` 명령 결과를 복사하고 `node-2`, `node-3` 에서 `kubeadm join` 명령을 실행합니다. 이 때, `--experimental-control-plane` 옵션을 추가하여 `Master` 역할을 부여하도록 설정합니다.

```bash
sudo kubeadm join 10.10.1.2:6443 \
--token fb8x4h.z6afmap8a757kojm \
--discovery-token-ca-cert-hash \
sha256:a062d83e9c49adad5403d12aa563bc72dc684ca09a822c511aa299103e2b5d72 \
--experimental-control-plane
```



## Multiple Control Plane Nodes

`kubectl get nodes` 명령을 이용해 노드 수와 역할을 확인해봅니다.

```bash
kubectl get nodes

NAME     STATUS   ROLES    AGE   VERSION
node-1   Ready    master   29m   v1.14.3
node-2   Ready    master   21m   v1.14.3
node-3   Ready    master   20m   v1.14.3
```



`Master` 역할을 하기 위해 필요한 `Pod` 들이 실행되고 있는지 여부도 확인합니다.

```bash
kubectl get po -n kube-system

NAME                             READY   STATUS    RESTARTS   AGE
coredns-fb8b8dccf-x54lm          1/1     Running   0          31m
coredns-fb8b8dccf-xpdhc          1/1     Running   0          31m
etcd-node-1                      1/1     Running   0          30m
etcd-node-2                      1/1     Running   0          23m
etcd-node-3                      1/1     Running   0          23m
kube-apiserver-node-1            1/1     Running   0          30m
kube-apiserver-node-2            1/1     Running   1          23m
kube-apiserver-node-3            1/1     Running   0          23m
kube-controller-manager-node-1   1/1     Running   1          30m
kube-controller-manager-node-2   1/1     Running   0          23m
kube-controller-manager-node-3   1/1     Running   0          23m
kube-proxy-25rln                 1/1     Running   0          23m
kube-proxy-rtw5p                 1/1     Running   0          23m
kube-proxy-vqqfx                 1/1     Running   0          31m
kube-scheduler-node-1            1/1     Running   1          30m
kube-scheduler-node-2            1/1     Running   0          22m
kube-scheduler-node-3            1/1     Running   0          23m
weave-net-gvq6m                  2/2     Running   1          23m
weave-net-qfpg9                  2/2     Running   0          23m
weave-net-rkxrw                  2/2     Running   0          29m
```



`kubeadm` 을 이용해 여러 대의  `Master`  노드로 구성된 클러스터를 구축하였습니다.

`Master` 노드만 있는 클러스터에서 컨테이너를 배포하기 위해 아래 명령을 실행합니다.

```bash
kubectl taint nodes --all node-role.kubernetes.io/master-

node/node-1 untainted
node/node-2 untainted
node/node-3 untainted
```



# Setup Highly Available Cluster

앞에서 생성한 Kubernetes 클러스터는 여러 대의 `Master` 노드를 가지고 있기 때문에, 한 대의 `Master` 노드에 문제가 생겨도 `etcd` 데이터가 유실되는 확률이 매우 줄어들었습니다. 

하지만, 클러스터가 가지고 있는`ControlPlaneEndpoint` 주소가 특정한 노드의 IP 주소이기 때문에 해당 노드가 실패할 경우에는 클러스터가 제대로 동작하지 않는 문제가 있습니다. 이를 극복하기 위해서 `ControlPlaneEndpoint` 에 `LoadBalancer` 주소를 할당하고, `LoadBalancer` 의 뒤에 `Master` 노드를 위치시키는 형태로 구성할 수 있습니다.

이번 실습에서는  `Keepalived` 데몬을 이용해 `LoadBalancer` 처럼 가용성을 확보할 수 있게 설정해보겠습니다.



## Setup Keepalived

`Keepalived` 는 고가용성 서버 시스템을 구축할 때 많이 사용하는 소프트웨어로, 여기에서는 `Master` 노드 앞에 위치하는 로드밸런서와 비슷한 역할을 하도록 설정하겠습니다.

> [Keepalived](https://www.keepalived.org/)

`Keepalived` 패키지를 설치하고 설정 파일을 작성하여 `Master` 노드를 가리킬 로드밸런서 IP 를 생성합니다.

```bash
sudo apt install -y keepalived

Reading package lists... Done
Building dependency tree       
Reading state information... Done
The following additional packages will be installed:
  ipvsadm libnl-3-200 libnl-genl-3-200 libnl-route-3-200 libsensors4 libsnmp-base libsnmp30
Suggested packages:
  heartbeat ldirectord lm-sensors snmp-mibs-downloader
The following NEW packages will be installed:
  ipvsadm keepalived libnl-3-200 libnl-genl-3-200 libnl-route-3-200 libsensors4 libsnmp-base libsnmp30
0 upgraded, 8 newly installed, 0 to remove and 6 not upgraded.
Need to get 1,672 kB of archives.
After this operation, 6,067 kB of additional disk space will be used.
Do you want to continue? [Y/n] 
...
Processing triggers for libc-bin (2.27-3ubuntu1) ...
Processing triggers for ureadahead (0.100.0-21) ...
Processing triggers for systemd (237-3ubuntu10.23) ...
Processing triggers for dbus (1.12.2-1ubuntu1.1) ..
```



**/etc/keepalived/keepalived.conf**

```
vrrp_instance VI_1 {
    state MASTER
    interface enp0s8
    virtual_router_id 10
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass mykeepalived-daemon
    }
    virtual_ipaddress {
        10.10.1.10/24
    }
    skip_check_adv_addr on
}
```



아래 명령을 이용해 바로 생성하는 것도 가능합니다.

```bash
sudo bash -c 'cat <<EOF > /etc/keepalived/keepalived.conf
vrrp_instance VI_1 {
    state MASTER
    interface enp0s8
    virtual_router_id 10
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass mykeepalived-daemon
    }
    virtual_ipaddress {
        10.10.1.10/24
    }
    skip_check_adv_addr on
}
EOF'
```



설정 파일을 작성하고 `keepalived` 데몬을 실행합니다.

```bash
sudo systemctl start keepalived
ping 10.10.1.10

PING 10.10.1.10 (10.10.1.10) 56(84) bytes of data.
64 bytes from 10.10.1.10: icmp_seq=1 ttl=64 time=0.035 ms
^C
--- 10.10.1.10 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.035/0.035/0.035/0.000 ms
```



서버를 재시작할 때에도 사용할 수 있도록 설정합니다.

```bash
sudo systemctl enable keepalived

Synchronizing state of keepalived.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable keepalived
```



## Change ControlPlaneEndpoint

실습 과정에 지정한 IP 를 그대로 사용하였다면, 현재 `ControlPlaneEndpoint` 는  `10.10.1.2` 입니다. 이 주소를  `keepalived` 서비스를 통해서 추가한 `10.10.1.10`  으로 변경하도록 하겠습니다.

`ControlPlaneEndpoint` 를 변경하기 위해서 수정해야 하는 것들을 나열해두었습니다.

**ConfigMaps**

* kube-system/kubeadm-config
* kube-system/kube-proxy
* kube-public/cluster-info

**System Config Files**

* /etc/kubernetes/admin.conf
* /etc/kubernetes/controller-manager.conf
* /etc/kubernetes/kubelet.conf
* /etc/kubernetes/scheduler.conf

**Certificates**

* /etc/kubernetes/pki/apiserver.crt
* /etc/kubernetes/pki/apiserver.key



## Edit ConfigMaps

ConfigMap 안에 있는 예전 IP 주소를 새로운 IP 주소로 변경합니다.

```bash
kubectl edit cm -n kube-system kubeadm-config
kubectl edit cm -n kube-system kube-proxy
kubectl edit cm -n kube-public cluster-info
```

기존 `ControlPlaneEndpoint` 주소인 `10.10.1.2` 를 `10.10.1.10` 으로 변경합니다.



## Edit Config Files

서버에서 사용하는 설정 파일 내용 중에 기존 IP 를 새로운 IP 로 변경합니다.

```bash
sudo vi /etc/kubernetes/admin.conf
sudo vi /etc/kubernetes/controller-manager.conf
sudo vi /etc/kubernetes/kubelet.conf
sudo vi /etc/kubernetes/scheduler.conf
```



## Regenerate Certificates

API Server 에 접속할 때 사용하는 인증서 안에는 기존 IP 가 그대로 남아있기 때문에, 새로 변경할 IP 를 넣어서 인증서를 다시 생성해야합니다.

이 때, 변경될 IP 등에 대한 정보를 미리 설정 파일에 기록해두고 이 파일을 사용합니다.

**change-config.yaml**

```yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.10.1.10"
  bindPort: 6443

---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: 1.14.4
apiServer:
  certSANs:
  - "10.10.1.10"
controlPlaneEndpoint: "10.10.1.10:6443"
```



인증서를 새로 생성하기 위해 기존 인증서를 삭제하고  `kubeadm init phase certs` 명령을 실행합니다.

```bash
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --config change-config.yaml

[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [node-1 kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 10.10.1.10 10.10.1.10 10.10.1.10
```



변경된 인증서를 `openssl` 명령을 이용해 확인해보겠습니다.

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text 

Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 2300864767022511301 (0x1fee5050aa96b4c5)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN = kubernetes
        ...
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication
            X509v3 Subject Alternative Name: 
                DNS:node-1, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:10.10.1.10, IP Address:10.10.1.10, IP Address:10.10.1.10
    Signature Algorithm: sha256WithRSAEncryption
         b3:5e:d5:bb:c4:86:95:7d:5c:42:b8:c4:87:f0:d2:5e:9f:a7:
         ...
```

`IP Address` 항목에 새롭게 변경하려는 IP 가 포함되어 있음을 확인할 수 있습니다.



새로 생성한 `apiserver.key`, `apiserver.crt` 파일을 다른 `Master` 노드에 복사합니다.

**copy-apiserver.sh**

```bash
USER=root
PRIV_KEY=/home/vagrant/.ssh/id_rsa
CONTROL_PLANE_IPS="10.10.1.3 10.10.1.4"
for host in ${CONTROL_PLANE_IPS}; do
    scp -i $PRIV_KEY /etc/kubernetes/pki/apiserver.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/apiserver.crt "${USER}"@$host:
done
```



`node-2`, `node-3` 에서는 `root` 권한으로 변경해서 두 파일을 기존 위치에 복사합니다. 

```bash
sudo su -
cp apiserver.crt apiserver.key /etc/kubernetes/pki/
```



## Restart Daemons and Pods

`ControlPlaneEndpoint`  정보를 모두 변경하고, 인증서를 새로 생성한 이후에 시스템 데몬과 `Pod` 를 새로 시작하여 바뀐 IP 를 적용하도록 하겠습니다.

`Master` 노드에서 앞에서 수정한 변경 내역을 한번에 반영할 수 있도록 `docker` 와 `kubelet` 데몬을 재시작합니다. 일반적으로 `Master` 노드에는 Kubernetes 와 관련된 컨테이너 외에는 동작시키지 않도록 설정해두기 때문에, 실제 동작하고 있는 서비스에 직접적인 영향을 주지 않을거라 예상됩니다.

```bash
sudo systemctl restart docker && sudo systemctl restart kubelet
```



이번 실습에서는 따로 구성해두지 않았지만, 만약에 `Worker` 노드가 존재한다면 `kubelet` 데몬을 재시작합니다.

```bash
sudo systemctl restart kubelet
```

> `Worker` 노드에는 인증서를 복사하는 작업이 필요없습니다.



`kubectl` 명령에서 사용하는 설정 파일 안에 있는 `ControlPlaneEndpoint` IP 또한 변경해주어야 합니다.

```bash
vi ~/.kube/config
```



변경된 인증서를 이용하는 `Pod` 들을 재시작하여야 하는데, 여기에서는 `kube-proxy`, `weave-net` 을 재시작하겠습니다. 만약에 더 많은 컨테이너들을 운영하고 있는 클러스터라면, 로그를 참조하여 인증서로 인해 연결이 거부되는 `Pod` 들을 재시작하여 변경된 인증서를 사용하도록 합니다.

```bash
kubectl get po -n kube-system | grep kube-proxy | awk '{ print $1 }' | xargs kubectl delete po -n kube-system

pod "kube-proxy-s2bp8" deleted
pod "kube-proxy-sl68v" deleted
pod "kube-proxy-t95c8" deleted
```

```bash
kubectl get po -n kube-system | grep weave-net | awk '{ print $1 }' | xargs kubectl delete po -n kube-system

pod "weave-net-gvq6m" deleted
pod "weave-net-qfpg9" deleted
pod "weave-net-rkxrw" deleted
```



## Check Cluster Health

클러스터가 제대로 동작하고 있는지 간단하게 `Pod` 을 생성해서 확인해보겠습니다.

```bash
kubectl create deploy nginx --image=nginx:latest

deployment.apps/nginx created
```

```bash
kubectl expose deploy nginx --type=NodePort --port=80 --target-port=80

service/nginx exposed
```



`NodePort` 로 열린 포트번호를 확인하고 내용을 확인합니다.

```bash
kubectl get svc

NAME         TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
kubernetes   ClusterIP   10.96.0.1      <none>        443/TCP        48m
nginx        NodePort    10.102.39.36   <none>        80:30336/TCP   48s
```

```bash
curl http://10.10.1.10:30336

<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body {
        width: 35em;
        margin: 0 auto;
        font-family: Tahoma, Verdana, Arial, sans-serif;
    }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
```



## Setup Standby Master Nodes

`10.10.1.2` 노드는 `keepalived` 데몬을 통해 `10.10.1.10` IP 주소를 가져오도록 설정이 되어있습니다. 해당 노드가 실패할 경우에는 다른 `Master` 노드에서 `ControlPlaneEndpoint`  역할을 하도록  `keepalived` 설정을 추가하도록 하겠습니다.

`node-2` 와 `node-3` 서버에도 `keepalived` 데몬을 설치하고 설정파일을 생성합니다. 이 때, `state` 에는 `BACKUP` 을 지정합니다. `auth_pass` 에는 기존에 설치되어 있는 `keepalived`  데몬에서 지정한 값과 같은 내용을 채워넣어야 합니다.

**/etc/keepalived/keepalived.conf**

```
vrrp_instance VI_1 {
    state BACKUP
    interface enp0s8
    virtual_router_id 10
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass mykeepalived-daemon
    }
    virtual_ipaddress {
        10.10.1.10/24
    }
    skip_check_adv_addr on
}
```

```bash
sudo bash -c 'cat <<EOF > /etc/keepalived/keepalived.conf
vrrp_instance VI_1 {
    state BACKUP
    interface enp0s8
    virtual_router_id 10
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass mykeepalived-daemon
    }
    virtual_ipaddress {
        10.10.1.10/24
    }
    skip_check_adv_addr on
}
EOF'
```



설정 파일을 작성하고 데몬을 시작합니다.

```bash
sudo systemctl start keepalived
sudo systemctl enable keepalived

Synchronizing state of keepalived.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable keepalived
```



`node-2`, `node-3` 에서 `keepalived` 설정을 마무리 한 이후에 `node-1` 을 종료시켜보도록 하겠습니다.

```bash
vagrant halt node-1

==> node-1: Attempting graceful shutdown of VM...
```

```bash
vagrant status

Current machine states:

node-gw                   running (virtualbox)
node-1                    poweroff (virtualbox)
node-2                    running (virtualbox)
node-3                    running (virtualbox)
```



이제 `node-2` 에 `kubectl` 을 실행할 수 있도록 환경을 설정합니다.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```



`kubectl` 명령을 이용해 `Node` 정보를 확인해보겠습니다.

```bash
kubectl get nodes

NAME     STATUS     ROLES    AGE     VERSION
node-1   NotReady   master   5h10m   v1.14.3
node-2   Ready      master   5h3m    v1.14.3
node-3   Ready      master   5h2m    v1.14.3
```



`node-1` 이 내려간 상태에서도 `kubectl` 을 이용해 명령을 실행하는 데는 문제가 없는 것을 확인할 수 있습니다.



노드 실패에 대한 탐지를 좀 더 민감하게 변경하기 위해서는 `/etc/kubernetes/manifests/kube-controller-manager.yaml` 파일 안에 `--node-monitor-period`, `--node-monitor-grace-period`,  `--pod-eviction-timeout`  옵션을 추가하면 도움이 됩니다.

```yaml
...
spec:
  containers:
  - command:
    - kube-controller-manager
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --controllers=*,bootstrapsigner,tokencleaner
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --use-service-account-credentials=true
    - --node-monitor-period=2s
    - --node-monitor-grace-period=16s
    - --pod-eviction-timeout=30s
```



다음 실습을 진행하기 위해 `node-1` 을 다시 시작합니다.

```bash
vagrant up node-1
```



# Show Etcd Cluster

## Install Etcdctl Client

`etcd` 클러스터 상태를 보기 위해서 `etcdctl` 클라이언트를 설치합니다.

```bash
sudo apt install -y etcd-client

Reading package lists... Done
Building dependency tree
Reading state information... Done
The following NEW packages will be installed:
  etcd-client
0 upgraded, 1 newly installed, 0 to remove and 18 not upgraded.
Need to get 8,137 kB of archives.
After this operation, 34.3 MB of additional disk space will be used.
Get:1 http://archive.ubuntu.com/ubuntu bionic/universe amd64 etcd-client amd64 3.2.17+dfsg-1 [8,137 kB]
Fetched 8,137 kB in 5s (1,606 kB/s)
Selecting previously unselected package etcd-client.
(Reading database ... 60428 files and directories currently installed.)
Preparing to unpack .../etcd-client_3.2.17+dfsg-1_amd64.deb ...
Unpacking etcd-client (3.2.17+dfsg-1) Setting up etcd-client (3.2.17+dfsg-1) Processing triggers for man-db (2.8.3-2ubuntu0.1) 
```



`etcdctl` 명령을 실행하면 아래와 같은 결과를 볼 수 있습니다.

```bash
etcdctl --version

etcdctl version: 3.2.17
API version: 2
```



**API version 3** 을 이용하기 위해서는 `ETCDCTL_API=3` 을 환경변수에 지정하고 실행하면 됩니다.

```bash
ETCDCTL_API=3 etcdctl version

etcdctl version: 3.2.17
API version: 3.2
```



## Etcd Member List

`etcdctl` 명령을 이용해 현재 구성되어 있는 클러스터 노드를 확인해보겠습니다.

```bash
sudo ETCDCTL_API=3 etcdctl \
 --endpoints=https://10.10.1.2:2379 \
 --cacert /etc/kubernetes/pki/etcd/ca.crt \
 --cert /etc/kubernetes/pki/etcd/peer.crt  \
 --key /etc/kubernetes/pki/etcd/peer.key \
member list
 
7b9762c6683894a, started, node-3, https://10.10.1.4:2380, https://10.10.1.4:2379
2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
65b34ee464867838, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
```



## Show Etcd Fields

`etcd` 에 저장된 모든 `key` 를 보기 위해서는 `get --from-key "" --keys-only` 명령을 사용합니다.

```bash
sudo ETCDCTL_API=3 etcdctl  \
 --endpoints=https://10.10.1.2:2379  \
 --cacert /etc/kubernetes/pki/etcd/ca.crt  \
 --cert /etc/kubernetes/pki/etcd/peer. crt   \
 --key /etc/kubernetes/pki/etcd/peer.key \
get --from-key "" --keys-only

/registry/apiregistration.k8s.io/apiservices/v1.
/registry/apiregistration.k8s.io/apiservices/v1.apps
/registry/apiregistration.k8s.io/apiservices/v1.authentication.k8s.io
/registry/apiregistration.k8s.io/apiservices/v1.authorization.k8s.io
/registry/apiregistration.k8s.io/apiservices/v1.autoscaling
/registry/apiregistration.k8s.io/apiservices/v1.batch
...
```



특정  `key`  를 지정해 내용을 확인하려면 아래와 같은 형식으로 명령을 실행합니다.

```bash
sudo ETCDCTL_API=3 etcdctl  \
  --endpoints=https://10.10.1.2:2379  \
  --cacert /etc/kubernetes/pki/etcd/ca.crt  \
  --cert /etc/kubernetes/pki/etcd/peer. crt   \
  --key /etc/kubernetes/pki/etcd/peer.key \
get /registry/services/specs/default/nginx -w json

{"header":{"cluster_id":16008628526375423153,"member_id":3379846022448203303,"revision":34198,"raft_term":12},"kvs":[{"key":"L3JlZ2lzdHJ5L3NlcnZpY2VzL3NwZWNzL2RlZmF1bHQvbmdpbng=","create_revision":8156,"mod_revision":8156,"version":1,"value":"azhzAAoNCgJ2MRIHU2VydmljZRK0AQpYCgVuZ2lueBIAGgdkZWZhdWx0IgAqJDhmN2VmNzZlLWEwYTctMTFlOS1iMWYxLTAyYTExOGMzYzgxMTIAOABCCAixpYfpBRAAWgwKA2FwcBIFbmdpbnh6ABJUChUKABIDVENQGFAiBggAEFAaACji+AESDAoDYXBwEgVuZ2lueBoMMTAuOTguNzIuMjAyIghOb2RlUG9ydDoETm9uZUIAUgBaB0NsdXN0ZXJgAGgAGgIKABoAIgA="}],"count":1}
```



# Manage Master Nodes

여러  `Master` 노드로 구성된 클러스터에서 하나씩 제거해서 단일 `Master`  노드로 구성된 클러스터로 다시 돌리는 실습을 진행해보겠습니다.

노드를 제거할 때 주의할 점은 `kubeadm reset` 을 먼저 실행해야 하는 것입니다. `kubeadm reset` 명령을 통해 노드를 제거하는 중간에 `etcd` 클러스터에서 현재 노드를 제거하는 작업을 진행합니다. 하지만, `kubectl delete node` 명령을 먼저 실행해둔 상황에서 `kubeadm reset` 명령은 `etcd` 클러스터를 조정하는 작업을 제대로 진행할 수 없어서 넘어가게 됩니다.

아래 실습에서는 `kubectl delete node` 명령을 통해 노드를 먼저 제거하고 `etcd` 클러스터에서 노드를 제거하는 작업을 수동으로 하는 것을 진행해보겠습니다.



## Remove  node-3

`kubectl delete node` 명령을 이용해 `node-3` 을 제거합니다.

```bash
kubectl delete node node-3

node "node-3" deleted
```



`node-3` 노드에서 `kubeadm reset` 명령을 실행합니다.

```bash
sudo kubeadm reset

[reset] Reading configuration from the cluster...
[reset] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -oyaml'
W0714 02:46:48.352340   22508 reset.go:73] [reset] Unable to fetch the kubeadm-config ConfigMap from cluster: failed to get node registration: faild to get corresponding node: nodes "node-3" not found
[reset] WARNING: Changes made to this host by 'kubeadm init' or 'kubeadm join' will be reverted.
[reset] Are you sure you want to proceed? [y/N]: y
[preflight] Running pre-flight checks
W0714 02:46:49.467010   22508 reset.go:234] [reset] No kubeadm config, using etcd pod spec to get data directory
[reset] Stopping the kubelet service
[reset] unmounting mounted directories in "/var/lib/kubelet"
[reset] Deleting contents of stateful directories: [/var/lib/etcd /var/lib/kubelet /etc/cni/net.d /var/lib/dockershim /var/run/kubernetes]
[reset] Deleting contents of config directories: [/etc/kubernetes/manifests /etc/kubernetes/pki]
[reset] Deleting files: [/etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf]

The reset process does not reset or clean up iptables rules or IPVS tables.
If you wish to reset iptables, you must do so manually.
For example:
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

If your cluster was setup to utilize IPVS, run ipvsadm --clear (or similar)
to reset your system's IPVS tables.
```



`iptables` 설정까지도 모두 초기화하기 위해서 `root` 계정으로 콘솔에 나온 명령을 실행합니다.

```bash
sudo su - 
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
systemctl restart docker
exit
```



제거한 이후 노드 정보와 `etcd` 클러스터 정보를 확인해보겠습니다.

```bash
kubectl get nodes

NAME     STATUS   ROLES    AGE     VERSION
node-1   Ready    master   6h21m   v1.14.3
node-2   Ready    master   6h14m   v1.14.3
```

```bash
sudo ETCDCTL_API=3 etcdctl  \
 --endpoints=https://10.10.1.2:2379  \
 --cacert /etc/kubernetes/pki/etcd/ca.crt  \
 --cert /etc/kubernetes/pki/etcd/peer.crt  \
 --key /etc/kubernetes/pki/etcd/peer.key \
 member list
 
7b9762c6683894a, started, node-3, https://10.10.1.4:2380, https://10.10.1.4:2379
2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
65b34ee464867838, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
```



Kubernetes 에서 `Master` 노드는 제거하였지만, `etcd` 클러스터 목록에는 아직 남아있는 것을 볼 수 있습니다. 이 상태에서 수동으로 `node-3` 을 제거해보겠습니다.

`etcdctl member remove` 명령을 실행해  `node-3` 노드를 삭제합니다.

```bash
sudo ETCDCTL_API=3 etcdctl  \
 --endpoints=https://10.10.1.2:2379  \
 --cacert /etc/kubernetes/pki/etcd/ca.crt  \
 --cert /etc/kubernetes/pki/etcd/peer.crt  \
 --key /etc/kubernetes/pki/etcd/peer.key \
member remove 7b9762c6683894a

Member  7b9762c6683894a removed from cluster de2a12d3cfcaccb1
```



삭제한 이후 `member list`  를 확인해보겠습니다.

```bash
sudo ETCDCTL_API=3 etcdctl  \
 --endpoints=https://10.10.1.2:2379  \
 --cacert /etc/kubernetes/pki/etcd/ca.crt  \
 --cert /etc/kubernetes/pki/etcd/peer.crt  \
 --key /etc/kubernetes/pki/etcd/peer.key \
member list

2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
65b34ee464867838, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
```



## Start etcd at node-3

`node-3` 을 Kubernetes 클러스터에서 제거하였습니다. 해당 노드는 Kubernetes 자원으로는 더 이상 사용되지 않지만,  별도의 `etcd` 클러스터로 사용하도록 설정을 추가해보겠습니다.

먼저, 기존  `etcd`  클러스터와 통신을 하기 위해서는 `/etc/kubernetes/pki/etcd` 디렉토리에 있는 인증서 파일이 필요합니다.



**copy-etcd.sh**

```bash
USER=root
PRIV_KEY=/home/vagrant/.ssh/id_rsa
CONTROL_PLANE_IPS="10.10.1.3 10.10.1.4"
for host in ${CONTROL_PLANE_IPS}; do
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.key "${USER}"@$host:
done
```

```bash
sudo ./copy-etcd.sh

ca.crt                      100% 1017   641.0KB/s   00:00
ca.key                      100% 1675     1.8MB/s   00:00
ca.crt                      100% 1017     1.3MB/s   00:00
ca.key                      100% 1675     2.0MB/s   00:00
```



`node-3` 에서 `ca.crt` 와 `ca.key` 파일을 `/etc/kubernetes/pki/etcd` 디렉토리로 복사(혹은 이동)합니다.

```bash
sudo su - 
mkdir -p /etc/kubernetes/pki/etcd
cp ca.crt ca.key /etc/kubernetes/pki/etcd/
```



인증서를 이용해서 `etcd` 에서 사용할 인증서를 생성합니다.

```bash
sudo kubeadm init phase certs etcd-server

I0714 03:15:43.583799   23842 version.go:240] remote version is much newer: v1.15.0; falling back to: stable-1.14
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [node-3 localhost] and IPs [10.10.1.4 127.0.0.1 ::1]
```

```bash
sudo kubeadm init phase certs etcd-peer

I0714 03:16:14.398629   23853 version.go:240] remote version is much newer: v1.15.0; falling back to: stable-1.14
[certs] Generating "etcd/peer" certificate and key
[certs] etcd/peer serving cert is signed for DNS names [node-3 localhost] and IPs [10.10.1.4 127.0.0.1 ::1]
```



생성한 인증서로 현재 `etcd` 클러스터 목록을 볼 수 있는지 확인해보겠습니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member list

72d810a18dfea09, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
```



`node-1` 에서 `etcdctl member add` 명령을 사용해  `node-3`  노드를 추가합니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member add node-3 --peer-urls=https://10.10.1.4:2380

Member d1b2a02160efbf38 added to cluster de2a12d3cfcaccb1
ETCD_NAME="node-3"
ETCD_INITIAL_CLUSTER="node-2=https://10.10.1.3:2380,node-1=https://10.10.1.2:2380,node-3=https://10.10.1.4:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
```

결과로 나온 값들은 `etcd` 서버를 실행할 때 환경변수로 정의하거나 인자로 넘겨줍니다.



새로 추가된 노드 목록을 확인합니다

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member list
   
72d810a18dfea09, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
d1b2a02160efbf38, unstarted, , https://10.10.1.4:2380,
```



`node-3` 에서 `etcd` 컨테이너를 실행하여 `etcd` 클러스터를 확장해보겠습니다.

```bash
sudo docker run --name etcd-node-3 -d  \
  -v /var/lib/etcd:/var/lib/etcd  \
  -v /etc/kubernetes/pki/etcd:/etc/kubernetes/pki/etcd  \
  --network host  \
  k8s.gcr.io/etcd:3.3.10 etcd  \
  --advertise-client-urls=https://10.10.1.4:2379  \
  --cert-file=/etc/kubernetes/pki/etcd/server.crt  \
  --client-cert-auth=true  \
  --data-dir=/var/lib/etcd  \
  --initial-advertise-peer-urls=https://10.10.1.4:2380  \
  --initial-cluster=node-2=https://10.10.1.3:2380,node-1=https://10.10.1.2:2380,node-3=https://10.10.1.4:2380  \
  --initial-cluster-state=existing  \
  --key-file=/etc/kubernetes/pki/etcd/server.key  \
  --listen-client-urls=https://10.10.1.4:2379  \
  --listen-peer-urls=https://10.10.1.4:2380  \
  --name=node-3  \
  --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt  \
  --peer-client-cert-auth=true  \
  --peer-key-file=/etc/kubernetes/pki/etcd/peer.key  \
  --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt  \
  --snapshot-count=10000  \
  --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```



`docker logs` 명령을 사용해 서버가 실행되고 있는 상태를 확인합니다.

```bash
260fcd982cef7cd52762e647479e49807b0b8e3fd9525981f851746dff036ab8
vagrant@node-3:/etc/kubernetes/manifests$ docker logs -f 260fcd

2019-07-14 07:29:38.830029 I | etcdmain: etcd Version: 3.3.10
2019-07-14 07:29:38.830087 I | etcdmain: Git SHA: 27fc7e2
2019-07-14 07:29:38.830090 I | etcdmain: Go Version: go1.10.4
2019-07-14 07:29:38.830092 I | etcdmain: Go OS/Arch: linux/amd64
2019-07-14 07:29:38.830095 I | etcdmain: setting maximum number of CPUs to 2, total number of available CPUs is 2
2019-07-14 07:29:38.830136 I | embed: peerTLS: cert = /etc/kubernetes/pki/etcd/peer.crt, key = /etc/kubernetes/pki/etcd/peer.key, ca = , trusted-ca = /etc/kubernetes/pki/etcd/ca.crt, client-cert-auth = true, crl-file =
2019-07-14 07:29:38.830552 I | embed: listening for peers on https://10.10.1.4:2380
2019-07-14 07:29:38.830591 I | embed: listening for client requests on 10.10.1.4:2379
2019-07-14 07:29:38.865142 I | etcdserver: name = node-3
2019-07-14 07:29:38.865160 I | etcdserver: data dir = /var/lib/etcd
2019-07-14 07:29:38.865167 I | etcdserver: member dir = /var/lib/etcd/member
2019-07-14 07:29:38.865172 I | etcdserver: heartbeat = 100ms
2019-07-14 07:29:38.865175 I | etcdserver: election = 1000ms
2019-07-14 07:29:38.865178 I | etcdserver: snapshot count = 10000
2019-07-14 07:29:38.865194 I | etcdserver: advertise client URLs = https://10.10.1.4:2379
2019-07-14 07:29:38.867086 I | etcdserver: starting member d1b2a02160efbf38 in cluster 
...
2019-07-14 07:29:45.921055 I | embed: ready to serve client requests
2019-07-14 07:29:45.930442 I | embed: serving client requests on 10.10.1.4:2379
```



`node-1` 에서 `etcd` 클러스터가 제대로 구성되었는지 확인해보겠습니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member list

72d810a18dfea09, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
d1b2a02160efbf38, started, node-3, https://10.10.1.4:2380, https://10.10.1.4:2379
```



## Add node-2 to etcd Cluster

`node-2` 를 Kubernetes 노드에서 제거하고 `etcd` 클러스터로 사용해보겠습니다. 여기에서는 정삭적인 방법으로 제거하고 `etcd` 클러스터에 추가해보겠습니다.



`kubeadm reset` 명령을 `node-2` 에서 먼저 실행합니다.

```bash
sudo kubeadm reset

[reset] Reading configuration from the cluster...
[reset] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -oyaml'[reset] WARNING: Changes made to this host by 'kubeadm init' or 'kubeadm join' will be reverted.
[reset] Are you sure you want to proceed? [y/N]: y
[preflight] Running pre-flight checks
[reset] Removing info for node "node-2" from the ConfigMap "kubeadm-config" in the "kube-system" Namespace
[reset] Stopping the kubelet service
[reset] unmounting mounted directories in "/var/lib/kubelet"
[reset] Deleting contents of stateful directories: [/var/lib/etcd /var/lib/kubelet /etc/cni/net.d /var/lib/dockershim /var/run/kubernetes]
[reset] Deleting contents of config directories: [/etc/kubernetes/manifests /etc/kubernetes/pki]
[reset] Deleting files: [/etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf]

The reset process does not reset or clean up iptables rules or IPVS tables.
If you wish to reset iptables, you must do so manually.
For example:
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

If your cluster was setup to utilize IPVS, run ipvsadm --clear (or similar)
to reset your system's IPVS tables.
```



`node-1` 에서 `kubectl delete node`  명령을 실행해 `node-2` 를 제거합니다.

```bash
kubectl delete node node-2

node "node-2" deleted
```



`etcd` 클러스터에서 `node-2` 가 제거된 것을 확인할 수 있습니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member list

2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
d1b2a02160efbf38, started, node-3, https://10.10.1.4:2380, https://10.10.1.4:2379
```



`etcd` 클러스터를 구성할 때 사용할 인증서 파일을 `node-2` 로 복사합니다.

```bash
sudo ./copy-etcd.sh

ca.crt                      100% 1017   641.0KB/s   00:00
ca.key                      100% 1675     1.8MB/s   00:00
ca.crt                      100% 1017     1.3MB/s   00:00
ca.key                      100% 1675     2.0MB/s   00:00
```



`/etc/kubernetes/pki/etcd/ca.crt` ,  `/etc/kubernetes/pki/etcd/ca.key`  파일을 복사하고 `kubeadm` 명령을 실행해 `etcd` 구성에 필요한 인증서 파일을 생성합니다.

```bash
sudo kubeadm init phase certs etcd-server

I0714 08:07:40.064768   12626 version.go:240] remote version is much newer: v1.15.0; falling back to: stable-1.14
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [node-2 localhost] and IPs [10.10.1.3 127.0.0.1 ::1]
```

```bash
sudo kubeadm init phase certs etcd-peer

I0714 08:07:47.565229   12634 version.go:240] remote version is much newer: v1.15.0; falling back to: stable-1.14
[certs] Generating "etcd/peer" certificate and key
[certs] etcd/peer serving cert is signed for DNS names [node-2 localhost] and IPs [10.10.1.3 127.0.0.1 ::1]
```



`node-1` 에서 `etcd` 클러스터에 `node-2` 를 추가합니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
member add node-2 --peer-urls=https://10.10.1.3:2380

Member 843a690a148d20a5 added to cluster de2a12d3cfcaccb1
ETCD_NAME="node-2"
ETCD_INITIAL_CLUSTER="node-1=https://10.10.1.2:2380,node-2=https://10.10.1.3:2380,node-3=https://10.10.1.4:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
```



`node-2` 에서 `etcd` 서버를 실행하여 `etcd`  노드를 추가합니다.

```bash
sudo docker run --name etcd-node-2 -d  \
  -v /var/lib/etcd:/var/lib/etcd  \
  -v /etc/kubernetes/pki/etcd:/etc/kubernetes/pki/etcd  \
  --network host  \
  k8s.gcr.io/etcd:3.3.10 etcd  \
  --advertise-client-urls=https://10.10.1.3:2379  \
  --cert-file=/etc/kubernetes/pki/etcd/server.crt  \
  --client-cert-auth=true  \
  --data-dir=/var/lib/etcd  \
  --initial-advertise-peer-urls=https://10.10.1.3:2380  \
  --initial-cluster=node-1=https://10.10.1.2:2380,node-2=https://10.10.1.3:2380,node-3=https://10.10.1.4:2380  \
  --initial-cluster-state=existing  \
  --key-file=/etc/kubernetes/pki/etcd/server.key  \
  --listen-client-urls=https://10.10.1.3:2379  \
  --listen-peer-urls=https://10.10.1.3:2380  \
  --name=node-2  \
  --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt  \
  --peer-client-cert-auth=true  \
  --peer-key-file=/etc/kubernetes/pki/etcd/peer.key  \
  --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt  \
  --snapshot-count=10000  \
  --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
dc663462bb967c64ce040064fcae5f98cdb7063ee7c6ce335751d11d42783aaa
```



`etcd` 로그를 확인합니다.

```bash
docker logs dc663
2019-07-14 08:16:00.218325 I | etcdmain: etcd Version: 3.3.10
2019-07-14 08:16:00.218520 I | etcdmain: Git SHA: 27fc7e2
2019-07-14 08:16:00.218579 I | etcdmain: Go Version: go1.10.4
2019-07-14 08:16:00.218616 I | etcdmain: Go OS/Arch: linux/amd64
2019-07-14 08:16:00.218654 I | etcdmain: setting maximum number of CPUs to 2, total number of available CPUs is 2
2019-07-14 08:16:00.218740 I | embed: peerTLS: cert = /etc/kubernetes/pki/etcd/peer.crt, key = /etc/kubernetes/pki/etcd/peer.key, ca = , trusted-ca = /etc/kubernetes/pki/etcd/ca.crt, client-cert-auth = true, crl-file =
2019-07-14 08:16:00.219284 I | embed: listening for peers on https://10.10.1.3:2380
2019-07-14 08:16:00.219409 I | embed: listening for client requests on 10.10.1.3:2379
2019-07-14 08:16:00.262697 I | etcdserver: name = node-2
2019-07-14 08:16:00.262730 I | etcdserver: data dir = /var/lib/etcd
2019-07-14 08:16:00.262737 I | etcdserver: member dir = /var/lib/etcd/member
2019-07-14 08:16:00.262742 I | etcdserver: heartbeat = 100ms
2019-07-14 08:16:00.262745 I | etcdserver: election = 1000ms
2019-07-14 08:16:00.262749 I | etcdserver: snapshot count = 10000
2019-07-14 08:16:00.262757 I | etcdserver: advertise client URLs = https://10.10.1.3:2379
2019-07-14 08:16:00.274627 I | etcdserver: starting member 843a690a148d20a5 in cluster de2a12d3cfcaccb1 2019-07-14 08:16:00.274687 I | raft: 843a690a148d20a5 became follower at term 0
2019-07-14 08:16:00.274700 I | raft: newRaft 843a690a148d20a5 [peers: [], term: 0, commit: 0, applied: 0, lastindex: 0, lastterm: 0]
2019-07-14 08:16:00.274706 I | raft: 843a690a148d20a5 became follower at term 1
2019-07-14 08:16:00.297223 W | auth: simple token is not cryptographically signed
2019-07-14 08:16:00.303777 I | rafthttp: started HTTP pipelining with peer 2ee7a00cdb8ac627
2019-07-14 08:16:00.303871 I | rafthttp: started HTTP pipelining with peer d1b2a02160efbf38
2019-07-14 08:16:00.303900 I | rafthttp: starting peer 2ee7a00cdb8ac627...
...
2019-07-14 08:16:07.322875 I | etcdserver: published {Name:node-2 ClientURLs:[https://10.10.1.3:2379]} to cluster de2a12d3cfcaccb1
2019-07-14 08:16:07.323692 I | embed: ready to serve client requests
2019-07-14 08:16:07.328200 I | embed: serving client requests on 10.10.1.3:2379
```



`node-1` 에서 `etcd` 서버 목록을 확인하여 `node-2` 가 제대로 연결되었는지 확인합니다.

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.2:2379 \
  --cacert=/etc/ kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etc d/server.key \
member list

2ee7a00cdb8ac627, started, node-1, https://10.10.1.2:2380, https://10.10.1.2:2379
843a690a148d20a5, started, node-2, https://10.10.1.3:2380, https://10.10.1.3:2379
d1b2a02160efbf38, started, node-3, https://10.10.1.4:2380, https://10.10.1.4:2379
```



## Kubernetes & Etcd Clusters

클러스터 현재 상태는 아래와 같습니다.



| Node    | IP          | Kubernetes | Etcd     | Description                   |
| ------- | ----------- | ---------- | -------- | ----------------------------- |
| node-1  | 10.10.1.2   | `Master`   | `node-1` |                               |
| node-2  | 10.10.1.3   |            | `node-2` | `docker run` 으로 실행        |
| node-3  | 10.10.1.4   |            | `node-3` | `docker run` 으로 실행        |
| node-gw | 10.10.1.254 |            |          | 클러스터에서 사용하는 Gateway |



# Summary

`Virtualbox` 와 `Vagrant` 를 이용한 VM 환경에서 Kubernetes 클러스터를 생성하고 관리하는 실습을 진행하였습니다. `keepalived` 데몬을 이용해 고가용성 `Master` 서버 환경을 추가하여 노드가 실패하는 경우에도 클러스터가 제대로 동작하는 것을 확인하였습니다. 

Kubernetes 클러스터를 관리하는 데 반드시 필요한 `etcd` 클러스터를 직접 추가하고 삭제하는 실습을 진행하였습니다. Kubernetes 클러스터 노드가 증가하거나 안정성을 강화하기 위해서`etcd` 클러스터를 생성하는 작업이 필요한 경우에 도움이 될 수 있을 것입니다.

