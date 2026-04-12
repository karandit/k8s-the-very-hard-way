#!/usr/bin/env bash

set -euo pipefail

echo "======= Installing containerd"
CONTAINERD_VERSION=2.2.1
curl --skip-existing -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION?}/containerd-${CONTAINERD_VERSION?}-linux-amd64.tar.gz"
sudo tar xzofC "containerd-${CONTAINERD_VERSION?}-linux-amd64.tar.gz" /usr/local

echo "======= Installing runc"
RUNC_VERSION=v1.4.0
curl --skip-existing -fsSLO "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION?}/runc.amd64"
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

echo "======= Configuring containerd"
sudo mkdir -p /etc/containerd
sudo cat <<EOF | sudo tee /etc/containerd/config.toml
version = 3

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
SystemdCgroup = true
EOF

echo "======= Installing CNI plugins"
CNI_PLUGINS_VERSION=v1.9.0
curl --skip-existing -fsSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION?}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION?}.tgz"
sudo mkdir -p /opt/cni/bin
sudo tar xzofC "cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION?}.tgz" /opt/cni/bin

echo "=======🚀 Starting containerd service"
curl --skip-existing -fsSLO "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION?}/containerd.service"
sudo cp containerd.service /etc/systemd/system 
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

echo "======= Installing kubelet"
KUBE_VERSION=v1.34.0
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kubelet"
sudo install -m 755 kubelet /usr/local/bin

echo "======= Configuring TLS for the kubelet API"
sudo mkdir -p /etc/kubernetes/pki
sudo cp /vagrant/ca.crt /etc/kubernetes/pki/ca.crt

echo "======= Configuring kubelet"
sudo mkdir -p /var/lib/kubelet/config.d
sudo cat <<EOF | sudo tee /var/lib/kubelet/config.d/99-cri.conf
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
cgroupDriver: systemd
EOF

sudo cat <<EOF | sudo tee /var/lib/kubelet/config.d/70-authnz.conf
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: false
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt

authorization:
  mode: AlwaysAllow
EOF

echo "======= Installing kubectl"
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kubectl"
sudo install -m 755 kubectl /usr/local/bin

echo "======= Creating a kubeconfig file for kubelet"
sudo kubectl config set-cluster default \
    --kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server=https://control-plane:6443

sudo kubectl config set-credentials default \
    --kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
    --token=abcdef.0123456789abcdef

sudo kubectl config set-context default \
    --kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
    --cluster=default \
    --user=default

sudo kubectl config use-context default \
    --kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf

echo "=======🚀 Starting kubelet service"
#curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/02-worker-node/02-kubelet/__static__/kubelet.service?v=1774217653
sudo cp /vagrant/kubelet.service.orig /etc/systemd/system/kubelet.service
sudo systemctl daemon-reload
sudo systemctl enable --now kubelet

echo "======= Status"
systemctl list-units -q kubelet.service containerd.service
