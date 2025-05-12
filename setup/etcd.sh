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

sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOF
[Unit]
Description=etcd Service
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=/usr/bin/etcd --name $HOSTNAME --discovery-srv $ROOT_DOMAIN --initial-advertise-peer-urls http://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2380 --initial-cluster-token etcd-homelab --initial-cluster-state new --advertise-client-urls http://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2379 --listen-client-urls http://0.0.0.0:2379 --listen-peer-urls http://0.0.0.0:2380 --data-dir /var/lib/etcd
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now etcd

# Setup consul service for etcd
sudo tee /etc/consul/etcd.hcl > /dev/null <<EOF
services {
  name = "etcd-client"
  id = "etcd-client-$HOSTNAME"
  port = 2379
  check = {
    id = "check-etcd-client-$HOSTNAME"
    name = "Check etcd client connection"
    http = "http://$HOSTNAME.node.homelab.$ROOT_DOMAIN:2379/readyz"
    interval = "10s"
    timeout = "2s"
  }
}
services {
  name = "etcd-server"
  id = "etcd-server-$HOSTNAME"
  port = 2380
}
EOF

sudo systemctl restart consul