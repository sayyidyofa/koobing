
#!/usr/bin/env python3
import subprocess
import os
import json
from pathlib import Path
from getpass import getuser

# Configuration
GATEWAY_IPS = ["192.168.1.101", "192.168.1.102", "192.168.1.103", "192.168.1.104", "192.168.1.105"]
GATEWAY_USER = getuser()
GATEWAY_HAPROXY_CFG = "/etc/haproxy/haproxy.cfg"
LOCAL_TMP_CFG = "/tmp/haproxy_service_block.cfg"

def ask_service_info():
    service = input("Enter service name (e.g. etcd): ").strip()
    domain = input(f"Enter service DNS name (default: {service}.service.consul): ").strip()
    if not domain:
        domain = f"{service}.service.consul"
    port_count = int(input("How many ports does the service expose? "))
    ports = []
    for _ in range(port_count):
        port = int(input("  Port number: "))
        lb = input("    Load balance this port? (y/n): ").strip().lower().startswith("y")
        hc = input("    Enable TCP health check? (y/n): ").strip().lower().startswith("y")
        ports.append({"port": port, "load_balance": lb, "health_check": hc})
    return service, domain, ports

def generate_haproxy_block(service, domain, ports):
    lines = []
    for p in ports:
        frontend = f"{service}_{p['port']}_front"
        backend = f"{service}_{p['port']}_back"
        lines.append(f"frontend {frontend}")
        lines.append(f"    bind *:{p['port']}")
        lines.append(f"    default_backend {backend}")
        lines.append("")
        lines.append(f"backend {backend}")
        lines.append(f"    server-template {service} 10 _{service}._tcp.{domain} resolvers consul_dns check inter 2s")
        if not p["load_balance"]:
            lines.append("    balance source")
        if p["health_check"]:
            lines.append("    option tcp-check")
        lines.append("")
    return "\n".join(lines)

def deploy_to_gateways(config_block):
    with open(LOCAL_TMP_CFG, "w") as f:
        f.write("\n" + config_block)

    for ip in GATEWAY_IPS:
        print(f"Deploying to {ip}...")
        ssh = ["ssh", f"{GATEWAY_USER}@{ip}"]
        scp = ["scp", LOCAL_TMP_CFG, f"{GATEWAY_USER}@{ip}:/tmp/"]
        subprocess.run(scp, check=True)

        check_cmd = f"grep -q '{config_block.splitlines()[0]}' {GATEWAY_HAPROXY_CFG} || " +                     f"(sudo tee -a {GATEWAY_HAPROXY_CFG} < /tmp/haproxy_service_block.cfg && sudo systemctl restart haproxy)"
        subprocess.run(ssh + [check_cmd], check=True)

def main():
    service, domain, ports = ask_service_info()
    config_block = generate_haproxy_block(service, domain, ports)
    deploy_to_gateways(config_block)
    print("Deployment complete.")

if __name__ == "__main__":
    main()
