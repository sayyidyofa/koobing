#!/usr/bin/env python3
import os
import subprocess
import sys
from getpass import getuser

GATEWAY_IPS = ["192.168.1.101", "192.168.1.102", "192.168.1.103", "192.168.1.104", "192.168.1.105"]
GATEWAY_USER = getuser()
HAPROXY_CFG = "/etc/haproxy/haproxy.cfg"

def run_ssh(ip, cmd):
    return subprocess.run(["ssh", f"{GATEWAY_USER}@{ip}", cmd], capture_output=True, text=True)

def update_haproxy_config(gateway_ip, service_name):
    result = run_ssh(gateway_ip, f"sudo cat {HAPROXY_CFG}")
    if result.returncode != 0:
        print(f"Failed to read config from {gateway_ip}: {result.stderr}")
        return False

    lines = result.stdout.splitlines()
    in_block = False
    start_idx = end_idx = -1

    for idx, line in enumerate(lines):
        if f"frontend {service_name}_front" in line or f"backend {service_name}_back" in line:
            if start_idx == -1:
                start_idx = idx
            in_block = True
        elif in_block and line.strip() == "":
            end_idx = idx
            break

    if start_idx == -1:
        print(f"[{gateway_ip}] No config block found for {service_name}")
        return False

    # Remove the block and save it back
    new_cfg = lines[:start_idx] + lines[end_idx + 1:]
    tmp_path = f"/tmp/haproxy_{service_name}.cfg"
    with open(tmp_path, "w") as f:
        f.write("\n".join(new_cfg) + "\n")

    subprocess.run(["scp", tmp_path, f"{GATEWAY_USER}@{gateway_ip}:{tmp_path}"], check=True)
    run_ssh(gateway_ip, f"sudo cp {tmp_path} {HAPROXY_CFG} && sudo systemctl reload haproxy")
    os.remove(tmp_path)
    print(f"[{gateway_ip}] Removed and reloaded HAProxy config for {service_name}")
    return True

def main():
    service_name = input("Enter the service name to deregister: ").strip()
    confirmed = input(f"Are you sure you want to deregister and remove HAProxy config for '{service_name}'? [y/N]: ").lower()
    if confirmed != "y":
        print("Aborted.")
        sys.exit(0)

    for gw in GATEWAY_IPS:
        try:
            update_haproxy_config(gw, service_name)
        except Exception as e:
            print(f"Error on {gw}: {e}")

if __name__ == "__main__":
    main()
