#!/bin/bash

# Function to install containerd
install_containerd() {
    sudo apt-get update
    sudo apt-get install -y containerd

    # Configure required modules for Kubernetes
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    # sysctl params required by setup, params persist across reboots
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Apply sysctl params without reboot
    sudo sysctl --system

    # Configure containerd
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml

    # Modify containerd to use SystemdCgroup
    sudo sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml

    # Restart containerd to apply changes
    sudo systemctl restart containerd
    sudo systemctl enable containerd
}

# Function to install kubeadm, kubelet, and kubectl
install_kubernetes_components() {
    sudo apt-get update && sudo apt-get install -y apt-transport-https curl
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    # Install specific versions of kubelet, kubeadm, and kubectl
    sudo apt-get install -y kubelet=1.27.0-00 kubeadm=1.27.0-00 kubectl=1.27.0-00
    sudo apt-mark hold kubelet kubeadm kubectl
}

setup_swapoff() {
    # Disable swap
    sudo swapoff -a
    # Comment the swap line in /etc/fstab to ensure it remains disabled after reboot
    sudo sed -i '/ swap / s/^/#/' /etc/fstab

    # Add a cron job to disable swap on reboot
    (crontab -l 2>/dev/null; echo "@reboot sudo swapoff -a") | crontab -
}

setup_restart_services_cron() {
    # Add a cron job to restart kubelet and containerd on reboot
    (crontab -l 2>/dev/null; echo "@reboot sudo systemctl restart kubelet containerd") | crontab -
}

# Ask the user if this is a control or worker node
echo "Is this a control node or a worker node? (Enter 'control' or 'worker')"
read NODE_TYPE

# Disable swap
setup_swapoff


# Install containerd
install_containerd

# Install Kubernetes components
install_kubernetes_components

setup_restart_services_cron


# Control Node Setup
if [ "$NODE_TYPE" = "control" ]; then
    # Pull Kubernetes images
    sudo kubeadm config images pull

    # Initialize Kubernetes Cluster
    sudo kubeadm init --pod-network-cidr=192.168.0.0/16

    # Set up local kubeconfig
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    # Install Calico networking version 3.25.0
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml

    # Create a token for joining worker nodes and display the join command
    JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)
    echo "Control node setup complete."
    echo "Use the following command to join worker nodes:"
    echo $JOIN_COMMAND

    # Restart kubelet
    sudo systemctl restart kubelet
elif [ "$NODE_TYPE" = "worker" ]; then
    echo "Worker node setup complete. Join this node to the cluster using the 'kubeadm join' command provided by the control node."
else
    echo "Invalid input. Please enter 'control' or 'worker'."
fi

