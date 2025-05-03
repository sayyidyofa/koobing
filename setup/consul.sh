#!/bin/bash

set -e

# --- Parameters ---
HOSTNAME="$1"
JOIN_IP="${2:-192.168.1.100}"
DATACENTER="homelab"

if [[ -z "$HOSTNAME" ]]; then
  echo "Usage: $0 <hostname> [join_ip]"
  exit 1
fi

echo "[*] Setting hostname to $HOSTNAME"
hostnamectl set-hostname "$HOSTNAME"

echo "[*] Installing dependencies"
apt-get update -y
apt-get install -y unzip curl jq

echo "[*] Installing Consul binary"
CONSUL_VERSION="1.16.2"
cd /tmp
curl -sLO "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip"
unzip "consul_${CONSUL_VERSION}_linux_amd64.zip"
chmod +x consul
mv consul /usr/local/bin/consul

echo "[*] Creating consul user and directories"
useradd --system --home /etc/consul.d --shell /bin/false consul || true
mkdir -p /etc/consul.d /var/lib/consul
chown -R consul:consul /etc/consul.d /var/lib/consul

echo "[*] Creating Consul client config"
cat >/etc/consul.d/client.json <<EOF
{
  "datacenter": "${DATACENTER}",
  "node_name": "${HOSTNAME}",
  "data_dir": "/var/lib/consul",
  "client_addr": "0.0.0.0",
  "retry_join": ["${JOIN_IP}"],
  "bind_addr": "$(hostname -I | awk '{print $1}')",
  "server": false,
  "enable_script_checks": true
}
EOF

chown consul:consul /etc/consul.d/client.json
chmod 640 /etc/consul.d/client.json

echo "[*] Creating systemd service unit for Consul"
cat >/etc/systemd/system/consul.service <<EOF
[Unit]
Description=Consul Agent
Requires=network-online.target
After=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
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
