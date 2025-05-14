#!/bin/bash

set -eu

HOSTNAME=$1
ROOT_DOMAIN=$2
VERSION=$3

wget "https://github.com/etcd-io/etcd/releases/download/$VERSION/etcd-$VERSION-linux-amd64.tar.gz"
tar -zxvf etcd-$VERSION-linux-amd64.tar.gz
sudo mv etcd-$VERSION-linux-amd64/etcd /usr/bin/
sudo mv etcd-$VERSION-linux-amd64/etcdctl /usr/bin/
sudo mv etcd-$VERSION-linux-amd64/etcdutl /usr/bin/
rm -rf etcd-$VERSION-linux-amd64.tar.gz
rm -rf etcd-$VERSION-linux-amd64

sudo rm -rf /var/lib/etcd
sudo mkdir -p /var/lib/etcd

sudo rm -rf /etc/etcd
sudo mkdir -p /etc/etcd
sudo tee /etc/etcd/conf.yml > /dev/null <<EOF
name $HOSTNAME 
discovery-srv service.$ROOT_DOMAIN 
initial-advertise-peer-urls https://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2380 
initial-cluster-token etcd-homelab 
initial-cluster-state new 
advertise-client-urls https://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2379 
listen-client-urls https://0.0.0.0:2379 
listen-peer-urls https://0.0.0.0:2380 
data-dir /var/lib/etcd
name: 'default'
EOF

sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOF
[Unit]
Description=etcd Service
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=/usr/bin/etcd --config-file /etc/etcd/conf.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
sudo systemctl restart etcd

# Setup consul service for etcd
sudo tee /etc/consul/etcd.hcl > /dev/null <<EOF
services {
  name = "etcd-client-tls"
  id = "etcd-client-tls-$HOSTNAME"
  port = 2379
  check = {
    id = "check-etcd-client-tls-$HOSTNAME"
    name = "Check etcd TLS client connection"
    http = "https://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2379/readyz"
    interval = "10s"
    timeout = "2s"
    tls_skip_verify = true
  }
}
services {
  name = "etcd-server-tls"
  id = "etcd-server-tls-$HOSTNAME"
  port = 2380
}
EOF

sudo systemctl restart consul