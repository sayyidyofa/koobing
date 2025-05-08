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

# machine id, hostname and local dns
sudo rm -rf /etc/machine-id
sudo systemd-machine-id-setup
sudo tee /etc/hosts > /dev/null <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
sudo systemctl enable --now systemd-resolved
sudo systemctl restart systemd-resolved
# Set hostname
sudo hostnamectl set-hostname $HOSTNAME

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

# Set Timezone
sudo timedatectl set-timezone Asia/Jakarta

echo "[*] Installing dependencies"
sudo apt-get update -y
sudo apt-get install -y unzip curl jq

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
sudo tee /etc/consul/config.json > /dev/null <<EOF
{
  "datacenter": "${DATACENTER}",
  "node_name": "${HOSTNAME}",
  "data_dir": "/var/lib/consul",
  "client_addr": "$IP_ADDRESS",
  "retry_join": [
    "192.168.1.101",
    "192.168.1.102",
    "192.168.1.103",
    "192.168.1.104",
    "192.168.1.105"
  ],
  "bind_addr": "$IP_ADDRESS",
  "server": false,
  "enable_script_checks": true
}
EOF

sudo chown consul:consul /etc/consul/config.json
sudo chmod 640 /etc/consul/config.json
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
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now consul
sudo systemctl restart consul

echo "[✓] Consul client installed and running on $HOSTNAME (datacenter: ${DATACENTER})"
