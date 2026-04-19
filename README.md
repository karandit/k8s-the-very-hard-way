# About

This repository replicates the environment from the [Kubernetes the (Very) Hard Way](https://labs.iximiuz.com/courses/kubernetes-the-very-hard-way-0cbfd997) course by Márk Sági-Kazár.

A huge thanks to Márk for providing such excellent educational material.

## Infrastructure

The project uses **Vagrant** and **VirtualBox** to provision three Virtual Machines:
- 1 **Control Plane** node
- 2 **Worker** nodes

## Networking & Caveats

By default, Vagrant creates a NAT interface at `eth0` for its own internal communication.
To avoid interfering with Vagrant's management of the VMs, I have added a `private_network` interface in the `Vagrantfile` to handle inter-node communication.

Using a secondary interface (`eth1`) introduced a few challenges, as several Kubernetes components expect `eth0` to be the default.
To address this, the following adjustments were made:
- **kubelet**: Added `--node-ip=${KUBELET_NODE_IP}` in `kubelet.service.orig` to ensure it binds to the correct internal IP.
- **flannel**: Added `--iface=eth1` in `flanneld.service.orig` to force the overlay network to use the private interface.

# Usage

```
vagrant status
vagrant up controlplane
vagrant ssh controlplane
cd /vagrant/.cache
/vagrant/setup-controlplane.sh
kubectl get node -owide -w
```

In new terminals:

```
vagrant up worker1
vagrant ssh worker1
cd /vagrant/.cache
/vagrant/setup-worker.sh
```

```
vagrant up worker2
vagrant ssh worker2
cd /vagrant/.cache
/vagrant/setup-worker.sh
```

Validating (switch to `controlplane`):
```
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:latest
          ports:
            - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
spec:
  selector:
    app: podinfo
  ports:
    - port: 80
      targetPort: 9898

---
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  containers:
    - name: curl
      image: ghcr.io/stefanprodan/podinfo:latest
      command: ["sh", "-c", "sleep infinity"]
EOF

kubectl exec client -- curl -fsS --max-time 5 "http://podinfo.default.svc:80"
```
