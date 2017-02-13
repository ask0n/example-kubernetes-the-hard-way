#! /bin/bash

# Bootstrapping Kubernetes Admin

## Install deps
apt-get update && apt-get -y install python-pip
pip install credstash==1.12.0

## Get the ssl certs
credstash -r us-west-2 get -n ssl/ca.pem > /usr/local/share/ca-certificates/ca.crt
update-ca-certificates

## Install kubectl
curl -s -X GET \
  https://storage.googleapis.com/kubernetes-release/release/v1.4.0/bin/linux/amd64/kubectl \
  -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

## Configure kubectl
sudo -u ubuntu kubectl config set-cluster kubernetes \
  --certificate-authority=/usr/local/share/ca-certificates/ca.crt \
  --embed-certs=true \
  --server=https://kubernetes:6443

sudo -u ubuntu kubectl config set-credentials admin --token $(credstash -r us-west-2 get -n ssl/token)

sudo -u ubuntu kubectl config set-context default-context \
  --cluster=kubernetes \
  --user=admin

sudo -u ubuntu kubectl config use-context default-context
