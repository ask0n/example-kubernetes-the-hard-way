#! /bin/bash

# Bootstrapping an H/A etcd cluster

## Install deps
apt-get clean && apt-get update && apt-get -y install python-pip
pip install credstash==1.12.0

## Get the ssl certs
mkdir -p /etc/etcd/
credstash -r us-west-2 get -n ssl/ca.pem > /etc/etcd/ca.pem
credstash -r us-west-2 get -n ssl/ca.pem > /usr/local/share/ca-certificates/ca.crt
update-ca-certificates
credstash -r us-west-2 get -n ssl/kubernetes-key.pem > /etc/etcd/kubernetes-key.pem
credstash -r us-west-2 get -n ssl/kubernetes.pem > /etc/etcd/kubernetes.pem
chmod 600 /etc/etcd/*.pem

## Install etcd
wget https://github.com/coreos/etcd/releases/download/v3.0.10/etcd-v3.0.10-linux-amd64.tar.gz
tar -xvf etcd-v3.0.10-linux-amd64.tar.gz
mv etcd-v3.0.10-linux-amd64/etcd* /usr/bin/
mkdir -p /var/lib/etcd

## Configure etcd
INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
ETCD_NAME=controller$(echo $INTERNAL_IP | cut -c 11)

cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/bin/etcd --name ETCD_NAME \
  --cert-file=/etc/etcd/kubernetes.pem \
  --key-file=/etc/etcd/kubernetes-key.pem \
  --peer-cert-file=/etc/etcd/kubernetes.pem \
  --peer-key-file=/etc/etcd/kubernetes-key.pem \
  --trusted-ca-file=/etc/etcd/ca.pem \
  --peer-trusted-ca-file=/etc/etcd/ca.pem \
  --initial-advertise-peer-urls https://INTERNAL_IP:2380 \
  --listen-peer-urls https://INTERNAL_IP:2380 \
  --listen-client-urls https://INTERNAL_IP:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://INTERNAL_IP:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster controller0=https://10.240.0.10:2380,controller1=https://10.240.0.11:2380,controller2=https://10.240.0.12:2380 \
  --initial-cluster-state new \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sed -i s/INTERNAL_IP/${INTERNAL_IP}/g /etc/systemd/system/etcd.service
sed -i s/ETCD_NAME/${ETCD_NAME}/g /etc/systemd/system/etcd.service

## Start etcd
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
systemctl status etcd --no-pager

# Bootstrapping an H/A Kubernetes Control Plane

## Get the certs
mkdir -p /var/lib/kubernetes
credstash -r us-west-2 get -n ssl/ca.pem > /var/lib/kubernetes/ca.pem
credstash -r us-west-2 get -n ssl/kubernetes-key.pem > /var/lib/kubernetes/kubernetes-key.pem
credstash -r us-west-2 get -n ssl/kubernetes.pem > /var/lib/kubernetes/kubernetes.pem
chmod 600 /var/lib/kubernetes/*.pem

## Setup Authentication and Authorization
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kube-apiserver
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kube-controller-manager
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kube-scheduler
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kubectl
chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/bin/

## Authentication
cat > /var/lib/kubernetes/token.csv <<EOF
$(credstash -r us-west-2 get -n ssl/token),admin,admin
$(credstash -r us-west-2 get -n ssl/token),scheduler,scheduler
$(credstash -r us-west-2 get -n ssl/token),kubelet,kubele
EOF
chmod 600 /var/lib/kubernetes/token.csv

## Authorization
cat > /var/lib/kubernetes/authorization-policy.jsonl <<EOF
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"*", "nonResourcePath": "*", "readonly": true}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"admin", "namespace": "*", "resource": "*", "apiGroup": "*", "nonResourcePath": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"scheduler", "namespace": "*", "resource": "*", "apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"kubelet", "namespace": "*", "resource": "*", "apiGroup": "*", "nonResourcePath": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"group":"system:serviceaccounts", "namespace": "*", "resource": "*", "apiGroup": "*", "nonResourcePath": "*"}}
EOF
chmod 600 /var/lib/kubernetes/authorization-policy.jsonl

cat > /etc/systemd/system/kube-apiserver.service <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-apiserver \
  --admission-control=NamespaceLifecycle,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota \
  --advertise-address=INTERNAL_IP \
  --allow-privileged=true \
  --apiserver-count=3 \
  --authorization-mode=ABAC \
  --authorization-policy-file=/var/lib/kubernetes/authorization-policy.jsonl \
  --bind-address=0.0.0.0 \
  --enable-swagger-ui=true \
  --etcd-cafile=/var/lib/kubernetes/ca.pem \
  --insecure-bind-address=0.0.0.0 \
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \
  --etcd-servers=https://10.240.0.10:2379,https://10.240.0.11:2379,https://10.240.0.12:2379 \
  --service-account-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --service-cluster-ip-range=10.32.0.0/24 \
  --service-node-port-range=30000-32767 \
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --token-auth-file=/var/lib/kubernetes/token.csv \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sed -i s/INTERNAL_IP/$INTERNAL_IP/g /etc/systemd/system/kube-apiserver.service

systemctl daemon-reload
systemctl enable kube-apiserver
systemctl start kube-apiserver
systemctl status kube-apiserver --no-pager

## Kubernetes Controller Manager

cat > /etc/systemd/system/kube-controller-manager.service <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-controller-manager \
  --allocate-node-cidrs=true \
  --cluster-cidr=10.200.0.0/16 \
  --cluster-name=kubernetes \
  --leader-elect=true \
  --master=http://INTERNAL_IP:8080 \
  --root-ca-file=/var/lib/kubernetes/ca.pem \
  --service-account-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --service-cluster-ip-range=10.32.0.0/24 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sed -i s/INTERNAL_IP/$INTERNAL_IP/g /etc/systemd/system/kube-controller-manager.service

systemctl daemon-reload
systemctl enable kube-controller-manager
systemctl start kube-controller-manager
systemctl status kube-controller-manager --no-pager

## Kubernetes Scheduler

cat > /etc/systemd/system/kube-scheduler.service <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-scheduler \
  --leader-elect=true \
  --master=http://INTERNAL_IP:8080 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sed -i s/INTERNAL_IP/$INTERNAL_IP/g /etc/systemd/system/kube-scheduler.service

systemctl daemon-reload
systemctl enable kube-scheduler
systemctl start kube-scheduler
systemctl status kube-scheduler --no-pager
