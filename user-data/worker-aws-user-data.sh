#! /bin/bash

# Bootstrapping Kubernetes Workers

## Install deps
apt-get clean && apt-get update && apt-get -y install python-pip
pip install credstash==1.12.0

## Get the ssl certs
mkdir -p /var/lib/kubernetes
credstash -r us-west-2 get -n ssl/ca.pem > /var/lib/kubernetes/ca.pem
credstash -r us-west-2 get -n ssl/ca.pem > /usr/local/share/ca-certificates/ca.crt
update-ca-certificates
credstash -r us-west-2 get -n ssl/kubernetes-key.pem > /var/lib/kubernetes/kubernetes-key.pem
credstash -r us-west-2 get -n ssl/kubernetes.pem > /var/lib/kubernetes/kubernetes.pem
chmod 600 /var/lib/kubernetes/*.pem

## Install docker
wget https://get.docker.com/builds/Linux/x86_64/docker-1.12.1.tgz
tar -xvf docker-1.12.1.tgz
cp docker/docker* /usr/bin/

cat > /etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io

[Service]
ExecStart=/usr/bin/docker daemon \
  --iptables=false \
  --ip-masq=false \
  --host=unix:///var/run/docker.sock \
  --log-level=error \
  --storage-driver=overlay
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker
systemctl start docker
docker version

## Install kubelet
mkdir -p /opt/cni
wget https://storage.googleapis.com/kubernetes-release/network-plugins/cni-07a8a28637e97b22eb8dfe710eeae1344f69d16e.tar.gz
tar -xvf cni-07a8a28637e97b22eb8dfe710eeae1344f69d16e.tar.gz -C /opt/cni
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kubectl
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kube-proxy
wget https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kubelet
chmod +x kubectl kube-proxy kubelet
mv kubectl kube-proxy kubelet /usr/bin/
mkdir -p /var/lib/kubelet/

cat > /var/lib/kubelet/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /var/lib/kubernetes/ca.pem
    server: https://10.240.0.10:6443
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kubelet
  name: kubelet
current-context: kubelet
users:
- name: kubelet
  user:
    token: $(credstash -r us-west-2 get -n ssl/token)
EOF

cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/kubelet \
  --allow-privileged=true \
  --api-servers=https://10.240.0.10:6443,https://10.240.0.11:6443,https://10.240.0.12:6443 \
  --cluster-dns=10.32.0.10 \
  --cluster-domain=cluster.local \
  --hostname-override=$(hostname -s) \
  --configure-cbr0=true \
  --container-runtime=docker \
  --docker=unix:///var/run/docker.sock \
  --network-plugin=kubenet \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --reconcile-cidr=true \
  --serialize-image-pulls=false \
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --cloud-provider=aws \
  --v=2

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kubelet
systemctl start kubelet

systemctl status kubelet --no-pager

cat > /etc/systemd/system/kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-proxy \
  --master=https://10.240.0.10:6443 \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --proxy-mode=iptables \
  --v=2

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kube-proxy
systemctl start kube-proxy

systemctl status kube-proxy --no-pager
