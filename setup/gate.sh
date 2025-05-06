#!/usr/bin/env bash
set -eu

HOSTNAME="$1"
IP_ADDRESS="$2"

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
        - 192.168.1.100
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
  "bind_addr": "$IP_ADDRESS",
  "client_addr": "0.0.0.0",
  "retry_join": [
    "192.168.1.101",
    "192.168.1.102",
    "192.168.1.103",
    "192.168.1.104",
    "192.168.1.105"
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
Description=Consul Server Agent
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
    rewrite name suffix .internal .service.consul
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

## Store Corefile in Consul KV
consul kv put coredns_corefile @/etc/coredns/Corefile
## Restart service on KV change
sudo tee /etc/coredns/watch.sh > /dev/null <<EOF
#!/bin/bash
set -e
echo "replacing config file..."
consul kv get coredns_corefile > /etc/coredns/Corefile
echo "restarting coredns service..."
systemctl restart coredns
EOF
sudo chmod +x /etc/coredns/watch.sh
## Watch Corefile in Consul KV
sudo tee /etc/systemd/system/coredns-watch.service > /dev/null <<EOF
[Unit]
Description=CoreDNS Config Watcher
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=consul watch -type=key -key=coredns_corefile /etc/coredns/watch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now coredns-watch

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
EOF
sudo systemctl reload haproxy
sudo systemctl enable --now haproxy

## Store haproxy cfg in Consul KV
consul kv put haproxy_cfg @/etc/haproxy/haproxy.cfg
## Restart service on KV change
sudo tee /etc/haproxy/watch.sh > /dev/null <<EOF
#!/bin/bash
set -e
echo "replacing config file..."
consul kv get haproxy_cfg > /etc/haproxy/haproxy.cfg
echo "restarting haproxy service..."
systemctl restart haproxy
EOF
sudo chmod +x /etc/haproxy/watch.sh
## Watch haproxy cfg in Consul KV
sudo tee /etc/systemd/system/haproxy-watch.service > /dev/null <<EOF
[Unit]
Description=HAProxy Config Watcher
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=consul watch -type=key -key=haproxy_cfg /etc/haproxy/watch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now haproxy-watch

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
}
EOF
sudo systemctl enable --now keepalived

## Store keepalived conf in Consul KV
consul kv put keepalived_conf @/etc/keepalived/keepalived.conf
## Restart service on KV change
sudo tee /etc/keepalived/watch.sh > /dev/null <<EOF
#!/bin/bash
set -e
echo "replacing config file..."
consul kv get keepalived_conf > /etc/keepalived/keepalived.conf
echo "restarting keepalived service..."
systemctl restart keepalived
EOF
sudo chmod +x /etc/keepalived/watch.sh
## Watch keepalived conf in Consul KV
sudo tee /etc/systemd/system/keepalived-watch.service > /dev/null <<EOF
[Unit]
Description=Keepalived Config Watcher
After=network-online.target consul.service
Requires=consul.service

[Service]
ExecStart=consul watch -type=key -key=keepalived_conf /etc/keepalived/watch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now keepalived-watch

# Remove bloat and housekeep
sudo apt purge packagekit polkitd -y
sudo apt autoremove -y

sudo reboot