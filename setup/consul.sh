#!/bin/bash

set -eu

# --- Parameters ---
HOSTNAME="$1"
IP_ADDRESS="$2"
DATACENTER="homelab"

if [[ -z "$HOSTNAME" ]]; then
  echo "Usage: $0 <hostname> [join_ip]"
  exit 1
fi

sudo systemd-machine-id-setup

# Set ip address
## Assuming the VM has an interface "ens18" that does not have dhcp, 
## with subnet 192.168.1.0/24
## and there is a dns server at 192.168.100.1 
sudo tee /etc/netplan/50-cloud-init.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    ens18:
      addresses:
      - "$IP_ADDRESS/24"
      nameservers:
        addresses:
        - 192.168.1.1
        - 192.168.100.1
        - 1.1.1.1
        search: []
      routes:
      - to: "default"
        via: "192.168.1.1"
EOF
sudo netplan apply

echo "[*] Setting hostname to $HOSTNAME"
hostnamectl set-hostname "$HOSTNAME"

# Set Timezone
sudo timedatectl set-timezone Asia/Jakarta

echo "[*] Installing dependencies"
apt-get update -y
apt-get install -y unzip curl jq

# Install Consul
## Consul will run as consul user
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install consul -y
sudo mkdir -p /var/lib/consul
sudo chown -R consul:consul /var/lib/consul
sudo mkdir -p /etc/consul
sudo chown -R consul:consul /etc/consul
echo "[*] Creating Consul client config"
sudo tee /etc/consul.d/client.json > /dev/null <<EOF
{
  "datacenter": "${DATACENTER}",
  "node_name": "${HOSTNAME}",
  "data_dir": "/var/lib/consul",
  "client_addr": "0.0.0.0",
  "retry_join": ["192.168.1.100"],
  "bind_addr": "$(hostname -I | awk '{print $1}')",
  "server": false,
  "enable_script_checks": true
}
EOF

chown consul:consul /etc/consul.d/client.json
chmod 640 /etc/consul.d/client.json
sudo tee /etc/systemd/system/consul.service > /dev/null <<EOF
[Unit]
Description=Consul Agent
After=network-online.target
Wants=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Enabling and starting Consul service"
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable consul
systemctl start consul

echo "[✓] Consul client installed and running on $HOSTNAME (datacenter: ${DATACENTER})"
