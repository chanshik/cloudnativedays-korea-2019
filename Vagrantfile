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
