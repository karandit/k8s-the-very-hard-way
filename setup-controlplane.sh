#!/usr/bin/env bash

set -euo pipefail

cd

echo "======= Installing etcd"
ETCD_VERSION=v3.6.4
curl --skip-existing -fsSLO "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION?}/etcd-${ETCD_VERSION?}-linux-amd64.tar.gz"
tar xzof "etcd-${ETCD_VERSION?}-linux-amd64.tar.gz"
sudo install -m 755 "etcd-${ETCD_VERSION?}-linux-amd64"/{etcd,etcdctl,etcdutl} /usr/local/bin

echo "======= Creaing etcd user"
sudo adduser \
    --system \
    --group \
    --disabled-login \
    --disabled-password \
    --home /var/lib/etcd \
    etcd

echo "======= Securing data in transit"
sudo mkdir -vp /etc/etcd/pki
sudo rm -vf /etc/etcd/pki/*
cd /etc/etcd/pki

# Create a Certificate Authority (CA) to sign certificates:
sudo openssl genrsa -out ca.key 4096
sudo openssl req -x509 -new -nodes -key ca.key -out ca.crt -subj "/CN=etcd" -sha256 -days 3650

# Create a config file for the server certificate:
cat <<EOF | sudo tee server.cnf
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
CN = server

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = $(hostname)
IP.1  = 127.0.0.1
IP.2  = ::1
IP.3 = $(ip -o -4 addr show | grep 'eth1' | awk '{split($4,a,"/"); print a[1]}' | paste -sd,)
EOF

# Generate the server certificate:
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -config server.cnf
sudo openssl x509 -req -in server.csr -out server.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365 -extfile server.cnf -extensions req_ext

# Generate a client certificate for the Kubernetes API server and other etcd clients:
sudo openssl genrsa -out client.key 2048
sudo openssl req -new -key client.key -out client.csr -subj "/CN=etcd/O=etcd"
sudo openssl x509 -req -in client.csr -out client.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
# Set ownership of all generated certificates and keys to the etcd user:
sudo chown -R etcd:etcd .
# Make the client key accessible to all users:
sudo chmod 644 client.key

cd

# Configure etcd to use TLS for server connections and mutual TLS for client authentication:
cat <<EOF | sudo tee /etc/default/etcd
ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:2379

ETCD_CLIENT_CERT_AUTH=true
ETCD_CERT_FILE=/etc/etcd/pki/server.crt
ETCD_KEY_FILE=/etc/etcd/pki/server.key
ETCD_TRUSTED_CA_FILE=/etc/etcd/pki/ca.crt

ETCD_NAME=$(hostname)
ETCD_ADVERTISE_CLIENT_URLS=https://$(hostname):2379

EOF

echo "=======🚀 Starting etcd service"
curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/03-control-plane/01-etcd/__static__/etcd.service?v=1774217654
sudo cp etcd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
sudo systemctl restart etcd

echo "======= Installing kube-apiserver"
KUBE_VERSION=v1.34.0
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kube-apiserver"
sudo install -m 755 kube-apiserver /usr/local/bin

echo "======= Configuring kube-apiserver"
sudo mkdir -p /etc/kubernetes/pki
cd /etc/kubernetes/pki
sudo openssl genrsa -out sa.key 2048
sudo openssl rsa -in sa.key -pubout -out sa.pub
cd
echo "iximiuz,admin,admin,system:masters" | sudo tee /etc/kubernetes/tokens.csv

echo "======= Securing kube-apiserver"
sudo mkdir -p /etc/kubernetes/pki
cd /etc/kubernetes/pki
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -nodes -key ca.key -out ca.crt \
  -subj "/CN=kubernetes" -sha256 -days 3650

cat <<EOF | sudo tee apiserver.cnf
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
CN = kube-apiserver

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = kubernetes
DNS.3 = kubernetes.default
DNS.4 = kubernetes.default.svc
DNS.5 = kubernetes.default.svc.cluster.local
DNS.6 = control-plane
IP.1  = 127.0.0.1
IP.2  = ::1
IP.3  = 10.96.0.1
IP.4  = $(ip -o -4 addr show | grep 'eth1' | awk '{split($4,a,"/"); print a[1]}' | paste -sd,)
EOF

sudo openssl genrsa -out apiserver.key 2048
sudo openssl req -new -key apiserver.key -out apiserver.csr -config apiserver.cnf
sudo openssl x509 -req -in apiserver.csr -out apiserver.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365 -extfile apiserver.cnf -extensions req_ext

sudo openssl genrsa -out admin.key 2048
sudo openssl req -new -key admin.key -out admin.csr -subj "/CN=admin/O=system:masters"
sudo openssl x509 -req -in admin.csr -out admin.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
sudo chmod 644 admin.key
cd

echo "======= Configuring kube-apiserver to kubelet communication"
cd /etc/kubernetes/pki

sudo openssl genrsa -out apiserver-kubelet-client.key 2048
sudo openssl req -new -key apiserver-kubelet-client.key -out apiserver-kubelet-client.csr -subj "/CN=kube-apiserver-kubelet-client/O=system:masters"
sudo openssl x509 -req -in apiserver-kubelet-client.csr -out apiserver-kubelet-client.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
cd

echo "=======🚀 Starting kube-apiserver service"
#curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/03-control-plane/02-kube-apiserver/__static__/kube-apiserver.service?v=1774217654
sudo cp /vagrant/kube-apiserver.service.orig /etc/systemd/system/kube-apiserver.service
sudo systemctl daemon-reload
sudo systemctl enable --now kube-apiserver
sudo systemctl restart kube-apiserver

echo "======= Installing kubectl"
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kubectl"
sudo install -m 755 kubectl /usr/local/bin

echo "======= Configuring kubectl"
kubectl config set-cluster default \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --server=https://localhost:6443
kubectl config set-credentials default \
    --client-certificate=/etc/kubernetes/pki/admin.crt \
    --client-key=/etc/kubernetes/pki/admin.key \
    --token=""
kubectl config set-context default \
    --cluster=default \
    --user=default
kubectl config use-context default

echo "======= Installing kube-scheduler"
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kube-scheduler"
sudo install -m 755 kube-scheduler /usr/local/bin

echo "======= Configuring kube-scheduler"
cd /etc/kubernetes/pki

sudo openssl genrsa -out scheduler.key 2048
sudo openssl req -new -key scheduler.key -out scheduler.csr -subj "/CN=system:kube-scheduler"
sudo openssl x509 -req -in scheduler.csr -out scheduler.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
cd

echo "======= Creating a kubeconfig file for kube-scheduler"
sudo kubectl config set-cluster default \
    --kubeconfig=/etc/kubernetes/scheduler.conf \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443

sudo kubectl config set-credentials default \
    --kubeconfig=/etc/kubernetes/scheduler.conf \
    --client-certificate=/etc/kubernetes/pki/scheduler.crt \
    --client-key=/etc/kubernetes/pki/scheduler.key \
    --embed-certs=true

sudo kubectl config set-context default \
    --kubeconfig=/etc/kubernetes/scheduler.conf \
    --cluster=default \
    --user=default

sudo kubectl config use-context default \
    --kubeconfig=/etc/kubernetes/scheduler.conf

echo "=======🚀 Starting kube-scheduler service"
curl --skip-existing -fsSLO https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/03-control-plane/03-kube-scheduler/__static__/kube-scheduler.service?v=1774217655
sudo cp kube-scheduler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kube-scheduler
sudo systemctl restart kube-scheduler

echo "======= Installing kube-controller-manager"
curl --skip-existing -fsSLO "https://dl.k8s.io/${KUBE_VERSION?}/bin/linux/amd64/kube-controller-manager"
sudo install -m 755 kube-controller-manager /usr/local/bin

echo "======= Configuring kube-controller-manager"
cd /etc/kubernetes/pki
sudo openssl genrsa -out controller-manager.key 2048
sudo openssl req -new -key controller-manager.key -out controller-manager.csr -subj "/CN=system:kube-controller-manager"
sudo openssl x509 -req -in controller-manager.csr -out controller-manager.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
cd

echo "======= Creating a kubeconfig file for kube-controller-manager"
sudo kubectl config set-cluster default \
    --kubeconfig=/etc/kubernetes/controller-manager.conf \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443

sudo kubectl config set-credentials default \
    --kubeconfig=/etc/kubernetes/controller-manager.conf \
    --client-certificate=/etc/kubernetes/pki/controller-manager.crt \
    --client-key=/etc/kubernetes/pki/controller-manager.key \
    --embed-certs=true

sudo kubectl config set-context default \
    --kubeconfig=/etc/kubernetes/controller-manager.conf \
    --cluster=default \
    --user=default

sudo kubectl config use-context default \
    --kubeconfig=/etc/kubernetes/controller-manager.conf

echo "=======🚀 Starting kube-controller-manager service"
curl --skip-existing -fsSLO  https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/03-control-plane/04-kube-controller-manager/__static__/kube-controller-manager.service?v=1774217655
sudo cp kube-controller-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kube-controller-manager
sudo systemctl restart kube-controller-manager

echo "======= Bootstrap tokens"
kubectl apply -f /vagrant/Secret.bootstrap-token-abcdef.yaml
kubectl apply -f /vagrant/ClusterRoleBinding.kubelet-bootstrap.yaml
kubectl apply -f /vagrant/ClusterRoleBinding.node-autoapprove-bootstrap.yaml
kubectl apply -f /vagrant/ClusterRoleBinding.node-autoapprove-certificate-rotation.yaml

echo "======= Share ca.crt"
cp /etc/kubernetes/pki/ca.crt /vagrant/

echo "======= Prerequisites for Flannel"
cd /etc/kubernetes/pki
sudo openssl genrsa -out flannel.key 2048
sudo openssl req -new -key flannel.key -out flannel.csr -subj "/CN=system:flannel"
sudo openssl x509 -req -in flannel.csr -out flannel.crt \
  -CA ca.crt -CAkey ca.key \
  -days 365
cd

echo "======= Create a kubeconfig for Flannel"
sudo kubectl config set-cluster default \
    --kubeconfig=/etc/kubernetes/flannel.conf \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server=https://control-plane:6443

sudo kubectl config set-credentials default \
    --kubeconfig=/etc/kubernetes/flannel.conf \
    --client-certificate=/etc/kubernetes/pki/flannel.crt \
    --client-key=/etc/kubernetes/pki/flannel.key \
    --embed-certs=true

sudo kubectl config set-context default \
    --kubeconfig=/etc/kubernetes/flannel.conf \
    --cluster=default \
    --user=default

sudo kubectl config use-context default \
    --kubeconfig=/etc/kubernetes/flannel.conf
sudo cp /etc/kubernetes/flannel.conf /vagrant

echo "======= Configure RBAC for Flannel"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:flannel
rules:
  - apiGroups:
      - ""
    resources:
      - pods
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:flannel
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: system:flannel
EOF

echo "======= Status"
systemctl list-units -q etcd.service kube-apiserver.service kube-scheduler.service kube-controller-manager.service
