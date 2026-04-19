#!/usr/bin/env bash

set -euo pipefail

sudo swapoff -a
sudo modprobe br_netfilter
sudo sysctl net.bridge.bridge-nf-call-iptables=1

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

sudo cat <<EOF | sudo tee /var/lib/kubelet/config.d/60-dns.conf
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

clusterDNS:
  - 192.168.56.10
clusterDomain: cluster.local
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

sudo cat <<EOF | sudo tee /etc/default/kubelet-ip
KUBELET_NODE_IP=$(ip -o -4 addr show | grep 'eth1' | awk '{split($4,a,"/"); print a[1]}' | paste -sd,)
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

echo "======= Installing Flannel"
FLANNEL_VERSION=v0.27.2
FLANNEL_PLUGIN_VERSION=v1.7.1-flannel2

curl --skip-existing -fsSLO "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION?}/flannel-${FLANNEL_VERSION?}-linux-amd64.tar.gz"
curl --skip-existing -fsSLO "https://github.com/flannel-io/cni-plugin/releases/download/${FLANNEL_PLUGIN_VERSION?}/cni-plugin-flannel-linux-amd64-${FLANNEL_PLUGIN_VERSION?}.tgz"

tar xzof "flannel-${FLANNEL_VERSION?}-linux-amd64.tar.gz"
tar xzof "cni-plugin-flannel-linux-amd64-${FLANNEL_PLUGIN_VERSION?}.tgz"

sudo install -m 755 flanneld /usr/local/bin
sudo install -m 755 flannel-amd64 /opt/cni/bin/flannel

echo "======= Configuring Flannel"
sudo mkdir -p /etc/flannel
sudo cat <<EOF | sudo tee /etc/flannel/net-conf.json
{
  "Network": "10.244.0.0/16",
  "EnableNFTables": false,
  "Backend": {
    "Type": "vxlan"
  }
}
EOF
sudo cat <<EOF | sudo tee /etc/cni/net.d/10-flannel.conflist
{
  "name": "cbr0",
  "cniVersion": "1.0.0",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOF
sudo cp /vagrant/flannel.conf /etc/kubernetes/flannel.conf

echo "=======🚀 Starting flanneld service"
# curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/04-cluster/02-network/__static__/flanneld.service?v=1774217657
sudo cp /vagrant/flanneld.service.orig /etc/systemd/system/flanneld.service
sudo systemctl daemon-reload
sudo systemctl enable --now flanneld

echo "======= Installing kube-proxy"
curl -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kube-proxy"
sudo install -m 755 kube-proxy /usr/local/bin

sudo cp /vagrant/kube-proxy.conf /etc/kubernetes/kube-proxy.conf

echo "======= Configuring kube-proxy"
sudo mkdir -p /etc/kubernetes/kube-proxy
sudo cat <<EOF | sudo tee /etc/kubernetes/kube-proxy/config.yaml
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration

clusterCIDR: 10.244.0.0/16

clientConnection:
  kubeconfig: /etc/kubernetes/kube-proxy.conf
EOF

echo "=======🚀 Starting kube-proxy service"
curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/04-cluster/03-kube-proxy/__static__/kube-proxy.service?v=1774217659
sudo cp kube-proxy.service /etc/systemd/system/kube-proxy.service
sudo systemctl daemon-reload
sudo systemctl enable --now kube-proxy

echo "======= Status"
systemctl list-units -q kubelet.service containerd.service flanneld.service kube-proxy.service
