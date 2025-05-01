#!/usr/bin/env bash
set -eu

HOSTNAME="$1"
IP_ADDRESS="$2"

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

# Set hostname
sudo hostnamectl set-hostname $HOSTNAME

# Set Timezone
sudo timedatectl set-timezone Asia/Jakarta

# Install Consul
## Consul will run as consul user
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install consul -y
sudo mkdir -p /var/lib/consul
sudo chown -R consul:consul /var/lib/consul
sudo mkdir -p /etc/consul
sudo chown -R consul:consul /etc/consul
sudo tee /etc/consul/config.json > /dev/null <<EOF
{
  "datacenter": "homelab",
  "node_name": "$HOSTNAME",
  "data_dir": "/var/lib/consul",
  "server": true,
  "bootstrap_expect": 5,
  "bind_addr": "0.0.0.0",
  "client_addr": "0.0.0.0",
  "retry_join": [
    "provider=dnssrv name=_consul-server._tcp.service.consul"
  ],
  "ui_config": {
    "enabled": true
  },
  "ports": {
    "https": -1
  },
  "dns_config": {
    "enable_truncate": true,
    "only_passing": true
  },
  "leave_on_terminate": true,
  "enable_script_checks": true
}
EOF
sudo tee /etc/systemd/system/consul.service > /dev/null <<EOF
[Unit]
Description=Consul Server + Client Agent
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
sudo systemctl daemon-reload
sudo systemctl enable --now consul

# Install CoreDNS
wget https://github.com/coredns/coredns/releases/download/v1.12.1/coredns_1.12.1_linux_amd64.tgz
tar -zxvf coredns_1.12.1_linux_amd64.tgz
rm -rf coredns_1.12.1_linux_amd64.tgz
chmod +x ./coredns
sudo mv coredns /usr/bin/
sudo mkdir -p /etc/coredns
sudo tee /etc/coredns/Corefile > /dev/null <<EOF
. {
    forward . 1.1.1.1
    log
    errors
}

internal. {
    rewrite name (.*)\.internal {1}.service.consul
    forward . 127.0.0.1:8600
    log
    errors
}

consul. {
    forward . 127.0.0.1:8600
    log
    errors
}
EOF
sudo tee /etc/systemd/system/coredns.service > /dev/null <<EOF
[Unit]
Description=CoreDNS
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=/usr/bin/coredns -conf /etc/coredns/Corefile
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now coredns

# Install HAProxy
sudo apt-get install -y --no-install-recommends software-properties-common
sudo add-apt-repository -y ppa:vbernat/haproxy-3.0
sudo apt install -y haproxy
sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	stats socket /run/haproxy/admin.sock mode 660 level admin
	stats timeout 30s
	user haproxy
	group haproxy
	daemon

	# Default SSL material locations
	ca-base /etc/ssl/certs
	crt-base /etc/ssl/private

	# See: https://ssl-config.mozilla.org/#server=haproxy&server-version=2.0.3&config=intermediate
        ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
        ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
	errorfile 400 /etc/haproxy/errors/400.http
	errorfile 403 /etc/haproxy/errors/403.http
	errorfile 408 /etc/haproxy/errors/408.http
	errorfile 500 /etc/haproxy/errors/500.http
	errorfile 502 /etc/haproxy/errors/502.http
	errorfile 503 /etc/haproxy/errors/503.http
	errorfile 504 /etc/haproxy/errors/504.http
# --- Our added config below ---

resolvers consul_dns
    nameserver dns1 127.0.0.1:53
    resolve_retries       3
    timeout resolve       1s
    hold valid            10s

frontend http_front
    bind *:80
    default_backend dynamic_back

backend dynamic_back
    server-template srv 10 _web._tcp.service.consul resolvers consul_dns check inter 2s
EOF
sudo systemctl reload haproxy
sudo systemctl enable --now haproxy

# Install Keepalived
sudo apt install -y keepalived
PRIORITY=$(python3 -c "import sys; print(sys.argv[1].split('.')[-1])" $IP_ADDRESS)
sudo mkdir -p /etc/keepalived
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOF
vrrp_instance VI_1 {
    state BACKUP
    interface ens18
    virtual_router_id 1
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    virtual_ipaddress {
        192.168.1.100
    }
    track_script {
        check_services
    }
}

vrrp_script check_services {
    script "/usr/local/bin/keepalived-health.sh"
    interval 2
    timeout 1
    fall 2
    rise 2
}
EOF
sudo tee /usr/local/bin/keepalived-health.sh > /dev/null <<EOF
#!/bin/bash

# Check if Consul is healthy
curl --silent --fail http://127.0.0.1:8500/v1/status/leader >/dev/null || exit 1

# Check if CoreDNS is listening on port 53
ss -lntup | grep ":53" | grep -q "coredns" || exit 1

# Check if HAProxy is listening on port 80
ss -lntup | grep ":80" | grep -q "haproxy" || exit 1

# All services healthy
exit 0
EOF
sudo chmod +x /usr/local/bin/keepalived-health.sh
sudo systemctl enable --now keepalived

# Remove bloat and housekeep
sudo apt purge packagekit polkitd -y
sudo apt autoremove -y

sudo reboot