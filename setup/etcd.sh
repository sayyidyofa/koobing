#!/bin/bash

set -eu

HOSTNAME=$1
ROOT_DOMAIN=$2
VERSION=$3
CERT_PATH="/etc/etcd/$HOSTNAME.crt"
CERT_PK_PATH="/etc/etcd/$HOSTNAME.key"
CA_PATH="/etc/ssl/certs/homelab.pem"

if sudo test -f "$CERT_PATH" && sudo test -f "$CERT_PK_PATH"; then
    echo "etcd ssl certificate and private key exists, continuing..."
else
    echo "etcd ssl certificate and private key DOESN'T EXIST! Exiting"
    exit 1
fi

# Setup consul service for etcd
sudo tee /etc/consul/etcd.hcl > /dev/null <<EOF
services {
  name = "etcd-client-ssl"
  id = "etcd-client-ssl-$HOSTNAME"
  port = 2379
}
services {
  name = "etcd-server-ssl"
  id = "etcd-server-ssl-$HOSTNAME"
  port = 2380
}
EOF

sudo systemctl enable --now consul
sudo systemctl restart consul
sudo systemctl status consul

wget "https://github.com/etcd-io/etcd/releases/download/$VERSION/etcd-$VERSION-linux-amd64.tar.gz"
tar -zxvf etcd-$VERSION-linux-amd64.tar.gz
sudo mv etcd-$VERSION-linux-amd64/etcd /usr/bin/
sudo mv etcd-$VERSION-linux-amd64/etcdctl /usr/bin/
sudo mv etcd-$VERSION-linux-amd64/etcdutl /usr/bin/
rm -rf etcd-$VERSION-linux-amd64.tar.gz
rm -rf etcd-$VERSION-linux-amd64

sudo rm -rf /var/lib/etcd
sudo mkdir -p /var/lib/etcd

#sudo rm -rf /etc/etcd
sudo mkdir -p /etc/etcd
sudo tee /etc/etcd/conf.yml > /dev/null <<EOF
name: $HOSTNAME 
discovery-srv: service.$ROOT_DOMAIN 
advertise-client-urls: https://$HOSTNAME.node.$ROOT_DOMAIN:2379
initial-advertise-peer-urls: https://$HOSTNAME.node.$ROOT_DOMAIN:2380 
initial-cluster-token: etcd-homelab 
initial-cluster-state: new  
listen-client-urls: https://0.0.0.0:2379 
listen-peer-urls: https://0.0.0.0:2380 
data-dir: /var/lib/etcd
client-transport-security:
  # Path to the client server TLS cert file.
  cert-file: $CERT_PATH

  # Path to the client server TLS key file.
  key-file: $CERT_PK_PATH

  # Enable client cert authentication.
  client-cert-auth: true

  # Path to the client server TLS trusted CA cert file.
  trusted-ca-file: $CA_PATH

  # Client TLS using generated certificates
  auto-tls: false

peer-transport-security:
  # Path to the peer server TLS cert file.
  cert-file: $CERT_PATH

  # Path to the peer server TLS key file.
  key-file: $CERT_PK_PATH

  # Enable peer client cert authentication.
  client-cert-auth: true

  # Path to the peer server TLS trusted CA cert file.
  trusted-ca-file: $CA_PATH

  # Peer TLS using generated certificates.
  auto-tls: false

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
sudo systemctl status etcd

# Add ca to trust store
#sudo apt install -y ca-certificates
#sudo cp $CA_PATH /usr/local/share/ca-certificates/homelab.crt
#sudo update-ca-certificates