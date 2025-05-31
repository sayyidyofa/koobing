#!/bin/bash

# Script for easy-to-use TLS certificate generation

# --- Configuration ---
DEFAULT_CERT_VALIDITY_DAYS=730 # 2 years
DEFAULT_CA_VALIDITY_DAYS=9125  # 25 years
OPENSSL_CNF="temp_openssl.cnf" # Temporary OpenSSL config file

# --- Helper Functions ---

# Function to clean up temporary files on exit
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f "$OPENSSL_CNF" "$OPENSSL_CNF.bak" # .bak might be created by sed on some systems
}
trap cleanup EXIT # Register cleanup function to run on script exit

# Function to convert string to kebab-case
kebab_case() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Function to prompt for input with an optional default value
prompt_input() {
    local prompt_message="$1"
    local default_value="$2"
    local variable_name="$3"
    local input

    if [ -n "$default_value" ]; then
        read -r -p "$prompt_message [$default_value]: " input
        eval "$variable_name=\"${input:-$default_value}\""
    else
        read -r -p "$prompt_message: " input
        eval "$variable_name=\"$input\""
    fi
}

# Function for yes/no prompts
prompt_yes_no() {
    local prompt_message="$1"
    local default_choice="${2:-yes}" # Default to 'yes' if not specified
    local choice

    while true; do
        if [[ "$default_choice" == "yes" ]]; then
            read -r -p "$prompt_message (Y/n): " choice
            choice="${choice:-Y}" # Default to Y if user just presses Enter
        else
            read -r -p "$prompt_message (y/N): " choice
            choice="${choice:-N}" # Default to N if user just presses Enter
        fi

        case "$choice" in
            [Yy]* ) return 0;; # Yes, return success (0)
            [Nn]* ) return 1;; # No, return failure (1)
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# Function to generate OpenSSL configuration file dynamically
generate_openssl_config() {
    local cn="$1"
    local eku="$2"
    local sans_dns_str="$3"
    local sans_ip_str="$4"
    local email_san="$5"

    echo "Generating OpenSSL configuration file ($OPENSSL_CNF)..."
    cat > "$OPENSSL_CNF" <<-EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $cn
EOF
    if [ -n "$email_san" ]; then
        echo "emailAddress = $email_san" >> "$OPENSSL_CNF"
    fi
    cat >> "$OPENSSL_CNF" <<-EOF

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = $eku
subjectAltName = @alt_names

[ alt_names ]
EOF
    local san_idx=1
    if [ -n "$sans_dns_str" ]; then
        IFS=',' read -r -a dns_array <<< "$sans_dns_str"
        for dns_name in "${dns_array[@]}"; do
            dns_name=$(echo "$dns_name" | xargs)
            if [ -n "$dns_name" ]; then
                echo "DNS.$san_idx = $dns_name" >> "$OPENSSL_CNF"; san_idx=$((san_idx + 1))
            fi
        done
    fi
    if [ -n "$sans_ip_str" ]; then
        IFS=',' read -r -a ip_array <<< "$sans_ip_str"
        for ip_addr in "${ip_array[@]}"; do
            ip_addr=$(echo "$ip_addr" | xargs)
            if [ -n "$ip_addr" ]; then
                echo "IP.$san_idx = $ip_addr" >> "$OPENSSL_CNF"; san_idx=$((san_idx + 1))
            fi
        done
    fi
    if [ -n "$email_san" ]; then
        echo "email.$san_idx = $email_san" >> "$OPENSSL_CNF"
    fi
    echo "OpenSSL configuration generated:"
    cat "$OPENSSL_CNF"; echo "---"
}

# Function to install CA certificate to system trust store
install_ca_to_trust_store() {
    local ca_cert_to_install="$1"
    if [ ! -f "$ca_cert_to_install" ]; then
        echo "Error: CA certificate file '$ca_cert_to_install' not found for installation."
        return 1
    fi

    local ca_file_name
    ca_file_name=$(basename "$ca_cert_to_install")

    echo "Attempting to install CA certificate '$ca_cert_to_install' to system trust store..."
    echo "This usually requires sudo privileges."

    if ! command -v sudo &> /dev/null; then
        echo "Error: 'sudo' command not found. Please install the CA certificate manually."
        return 1
    fi

    local os_type=""
    if [[ "$(uname)" == "Linux" ]]; then
        if grep -q -i "ubuntu" /etc/os-release 2>/dev/null || grep -q -i "debian" /etc/os-release 2>/dev/null; then
            os_type="debian_ubuntu"
        elif grep -q -i "fedora" /etc/os-release 2>/dev/null || grep -q -i "centos" /etc/os-release 2>/dev/null || grep -q -i "rhel" /etc/os-release 2>/dev/null; then
            os_type="fedora_rhel"
        else
            os_type="linux_other"
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        os_type="macos"
    fi

    case "$os_type" in
        debian_ubuntu)
            echo "Detected Debian/Ubuntu based system."
            local target_dir="/usr/local/share/ca-certificates"
            echo "Copying CA certificate to $target_dir/$ca_file_name..."
            sudo mkdir -p "$target_dir"
            if sudo cp "$ca_cert_to_install" "$target_dir/$ca_file_name"; then
                echo "Running 'sudo update-ca-certificates'..."
                if sudo update-ca-certificates; then
                    echo "CA certificate successfully installed and trust store updated."
                else
                    echo "Error: 'sudo update-ca-certificates' failed. Please check for errors."
                    echo "You may need to remove the copied file: sudo rm '$target_dir/$ca_file_name'"
                fi
            else
                echo "Error: Failed to copy CA certificate using sudo. Check permissions or run script with sudo."
            fi
            ;;
        fedora_rhel)
            echo "Detected Fedora/RHEL based system."
            local target_dir="/etc/pki/ca-trust/source/anchors"
            echo "Copying CA certificate to $target_dir/$ca_file_name..."
            sudo mkdir -p "$target_dir"
            if sudo cp "$ca_cert_to_install" "$target_dir/$ca_file_name"; then
                echo "Running 'sudo update-ca-trust extract'..."
                if sudo update-ca-trust extract; then
                    echo "CA certificate successfully installed and trust store updated."
                else
                    echo "Error: 'sudo update-ca-trust extract' failed. Please check for errors."
                    echo "You may need to remove the copied file: sudo rm '$target_dir/$ca_file_name'"
                fi
            else
                echo "Error: Failed to copy CA certificate using sudo. Check permissions or run script with sudo."
            fi
            ;;
        macos)
            echo "Detected macOS system."
            echo "Attempting to install CA with 'sudo security add-trusted-cert'..."
            if sudo security add-trusted-cert -d -r trustRoot -k "/Library/Keychains/System.keychain" "$ca_cert_to_install"; then
                echo "CA certificate successfully installed to System keychain."
            else
                echo "Error: 'sudo security add-trusted-cert' failed. Please check for errors."
                echo "Ensure you have permissions and the System keychain is not locked."
            fi
            ;;
        *)
            echo "Unsupported OS or OS could not be reliably detected for automatic CA installation."
            echo "Please install '$ca_cert_to_install' into your system's trust store manually."
            echo "General steps for Linux: Copy to /usr/local/share/ca-certificates/ and run 'sudo update-ca-certificates'."
            echo "For macOS: Use Keychain Access utility or 'security add-trusted-cert' command."
            ;;
    esac
}


# --- Main Script Logic ---

echo "========================================"
echo " Interactive TLS Certificate Generator "
echo "========================================"
echo

if ! command -v openssl &> /dev/null; then
    echo "Error: openssl command not found. Please install OpenSSL and ensure it's in your PATH."
    exit 1
fi

CA_CERT_PATH=""
CA_KEY_PATH=""
CA_SERIAL_PATH=""
NEW_CA_GENERATED="false" # Flag to track if a new CA was generated in this run

# Default names for EXISTING CA files if user has them
DEFAULT_EXISTING_CA_CERT_NAME="ca.crt"
DEFAULT_EXISTING_CA_KEY_NAME="ca.key"
DEFAULT_EXISTING_CA_SERIAL_NAME="ca.srl"

if prompt_yes_no "Do you have an existing CA certificate and key?"; then
    while true; do
        prompt_input "Enter path to CA certificate file" "$DEFAULT_EXISTING_CA_CERT_NAME" CA_CERT_PATH
        if [ -f "$CA_CERT_PATH" ]; then break; else echo "File not found: $CA_CERT_PATH. Please try again."; fi
    done
    while true; do
        prompt_input "Enter path to CA private key file" "$DEFAULT_EXISTING_CA_KEY_NAME" CA_KEY_PATH
        if [ -f "$CA_KEY_PATH" ]; then break; else echo "File not found: $CA_KEY_PATH. Please try again."; fi
    done
    prompt_input "Enter path to CA serial file (will be created if it doesn't exist)" "$DEFAULT_EXISTING_CA_SERIAL_NAME" CA_SERIAL_PATH
else
    NEW_CA_GENERATED="true"
    echo "Generating a new CA..."
    
    prompt_input "Enter Common Name (CN) for the new CA" "My Local CA" CA_CN
    DEFAULT_CA_FILENAME_PREFIX=$(kebab_case "$CA_CN")
    if [ -z "$DEFAULT_CA_FILENAME_PREFIX" ]; then # Fallback if CN is empty or results in empty kebab
        DEFAULT_CA_FILENAME_PREFIX="my-ca"
    fi
    prompt_input "Enter filename prefix for the new CA files (cert, key, srl)" "$DEFAULT_CA_FILENAME_PREFIX" CA_FILENAME_PREFIX

    CA_CERT_PATH="${CA_FILENAME_PREFIX}.crt"
    CA_KEY_PATH="${CA_FILENAME_PREFIX}.key"
    CA_SERIAL_PATH="${CA_FILENAME_PREFIX}.srl"

    prompt_input "Enter Organization (O) for the new CA" "My Organization" CA_O
    prompt_input "Enter Country (C) for the new CA (2-letter code)" "US" CA_C

    echo "Generating CA private key ($CA_KEY_PATH)..."
    if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$CA_KEY_PATH"; then
        echo "Error generating CA private key."; exit 1
    fi
    chmod 400 "$CA_KEY_PATH"

    echo "Generating CA certificate ($CA_CERT_PATH, valid for $DEFAULT_CA_VALIDITY_DAYS days)..."
    SUBJECT_DN="/CN=$CA_CN/O=$CA_O/C=$CA_C"
    if ! openssl req -x509 -new -nodes -key "$CA_KEY_PATH" -sha256 -days "$DEFAULT_CA_VALIDITY_DAYS" -out "$CA_CERT_PATH" -subj "$SUBJECT_DN" \
        -addext "basicConstraints = critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage = critical,keyCertSign,cRLSign"; then
        echo "Error generating CA certificate."; exit 1
    fi
    echo "New CA generated: $CA_CERT_PATH, $CA_KEY_PATH, $CA_SERIAL_PATH (will be created on first signing)"

    if prompt_yes_no "Install the new CA certificate ('$CA_CERT_PATH') to the system trust store? (Requires sudo)"; then
        install_ca_to_trust_store "$CA_CERT_PATH"
    fi
fi
echo

echo "Select certificate purpose:"
echo "1) SSL Server Authentication only (for web servers, etc.)"
echo "2) mTLS (Server Authentication + Client Authentication)"
echo "3) Client Authentication only (for client-side identification)"
CERT_PURPOSE_CHOICE=""
while [[ ! "$CERT_PURPOSE_CHOICE" =~ ^[1-3]$ ]]; do
    prompt_input "Enter your choice (1-3)" "1" CERT_PURPOSE_CHOICE
done

EKU=""
case "$CERT_PURPOSE_CHOICE" in
    1) EKU="serverAuth";;
    2) EKU="serverAuth, clientAuth";;
    3) EKU="clientAuth";;
esac
echo

echo "Select signing algorithm for the new certificate's key:"
echo "1) RSA 2048 bits"
echo "2) RSA 4096 bits"
echo "3) ECDSA prime256v1 (NIST P-256)"
echo "4) ECDSA secp384r1 (NIST P-384)"
ALGO_CHOICE=""
while [[ ! "$ALGO_CHOICE" =~ ^[1-4]$ ]]; do
    prompt_input "Enter your choice (1-4)" "1" ALGO_CHOICE
done

KEY_TYPE=""; KEY_PARAM=""; KEY_GEN_CMD=""
case "$ALGO_CHOICE" in
    1) KEY_TYPE="RSA"; KEY_PARAM="2048"; KEY_GEN_CMD="openssl genrsa -out";;
    2) KEY_TYPE="RSA"; KEY_PARAM="4096"; KEY_GEN_CMD="openssl genrsa -out";;
    3) KEY_TYPE="EC"; KEY_PARAM="prime256v1"; KEY_GEN_CMD="openssl ecparam -name $KEY_PARAM -genkey -noout -out";;
    4) KEY_TYPE="EC"; KEY_PARAM="secp384r1"; KEY_GEN_CMD="openssl ecparam -name $KEY_PARAM -genkey -noout -out";;
esac
echo

CERT_CN=""; DNS_SANS=""; IP_SANS=""; USER_EMAIL=""; IS_MACHINE_CLIENT=""
OUTPUT_PREFIX=""
while [ -z "$OUTPUT_PREFIX" ]; do
    prompt_input "Enter a prefix for output file names (e.g., my_server, client_john)" "" OUTPUT_PREFIX
    if [ -z "$OUTPUT_PREFIX" ]; then echo "Error: Output prefix cannot be empty."; fi
done

CERT_KEY_PATH="${OUTPUT_PREFIX}.key"
CERT_CSR_PATH="${OUTPUT_PREFIX}.csr"
CERT_PATH="${OUTPUT_PREFIX}.crt"

if [ "$CERT_PURPOSE_CHOICE" -eq 3 ]; then # Client Authentication only
    if prompt_yes_no "Is this client certificate for a machine?"; then
        IS_MACHINE_CLIENT="yes"
        prompt_input "Enter Common Name (CN) for the machine client certificate" "client.internal.example.com" CERT_CN
        prompt_input "Enter comma-separated DNS SANs (e.g., app1.internal,app2.internal)" "" DNS_SANS
        prompt_input "Enter comma-separated IP SANs (e.g., 10.0.0.5,10.0.0.6)" "" IP_SANS_USER
        IP_SANS="127.0.0.1${IP_SANS_USER:+,}${IP_SANS_USER}" # Prepend 127.0.0.1, add comma if user provided IPs
        IP_SANS=$(echo "$IP_SANS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    else # Human client
        IS_MACHINE_CLIENT="no"
        EKU="clientAuth, emailProtection"
        prompt_input "Enter Common Name (CN) for the human client certificate (e.g., John Doe)" "" CERT_CN
        prompt_input "Enter Email address for the human client (for Subject E and rfc822Name SAN)" "" USER_EMAIL
    fi
else # Server Authentication or mTLS
    prompt_input "Enter Common Name (CN) for the certificate (e.g., server.example.com)" "" CERT_CN
    prompt_input "Enter comma-separated DNS SANs (e.g., www.example.com,api.example.com)" "$CERT_CN" DNS_SANS
    prompt_input "Enter comma-separated IP SANs (e.g., 192.168.1.100)" "" IP_SANS_USER
    IP_SANS="127.0.0.1${IP_SANS_USER:+,}${IP_SANS_USER}"
    IP_SANS=$(echo "$IP_SANS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
fi
echo

prompt_input "Enter certificate validity period in days" "$DEFAULT_CERT_VALIDITY_DAYS" CERT_VALIDITY_DAYS
if ! [[ "$CERT_VALIDITY_DAYS" =~ ^[0-9]+$ ]] || [ "$CERT_VALIDITY_DAYS" -le 0 ]; then
    echo "Invalid validity period. Using default: $DEFAULT_CERT_VALIDITY_DAYS days."
    CERT_VALIDITY_DAYS=$DEFAULT_CERT_VALIDITY_DAYS
fi
echo

echo "Generating private key ($CERT_KEY_PATH) using $KEY_TYPE $KEY_PARAM..."
if [ "$KEY_TYPE" == "RSA" ]; then
    if ! $KEY_GEN_CMD "$CERT_KEY_PATH" "$KEY_PARAM"; then echo "Error generating private key."; exit 1; fi
else
    if ! $KEY_GEN_CMD "$CERT_KEY_PATH"; then echo "Error generating private key."; exit 1; fi
fi
chmod 400 "$CERT_KEY_PATH"
echo "Private key generated: $CERT_KEY_PATH"; echo

echo "Generating CSR ($CERT_CSR_PATH)..."
CSR_SUBJ_STR="/CN=$CERT_CN"
if [ "$IS_MACHINE_CLIENT" == "no" ] && [ -n "$USER_EMAIL" ]; then
    CSR_SUBJ_STR="$CSR_SUBJ_STR/emailAddress=$USER_EMAIL"
fi
if ! openssl req -new -key "$CERT_KEY_PATH" -out "$CERT_CSR_PATH" -subj "$CSR_SUBJ_STR"; then
    echo "Error generating CSR."; exit 1
fi
echo "CSR generated: $CERT_CSR_PATH"; echo

generate_openssl_config "$CERT_CN" "$EKU" "$DNS_SANS" "$IP_SANS" "$USER_EMAIL"

echo "Signing the certificate ($CERT_PATH) with CA: $CA_CERT_PATH..."
echo "Using CA key: $CA_KEY_PATH"
echo "Using CA serial file: $CA_SERIAL_PATH (will be created if it doesn't exist)"
echo "Certificate will be valid for $CERT_VALIDITY_DAYS days."

SERIAL_DIR=$(dirname "$CA_SERIAL_PATH")
if [ ! -d "$SERIAL_DIR" ]; then mkdir -p "$SERIAL_DIR"; fi

if ! openssl x509 -req -in "$CERT_CSR_PATH" \
    -CA "$CA_CERT_PATH" -CAkey "$CA_KEY_PATH" \
    -CAserial "$CA_SERIAL_PATH" -CAcreateserial \
    -out "$CERT_PATH" -days "$CERT_VALIDITY_DAYS" -sha256 \
    -extfile "$OPENSSL_CNF" -extensions v3_req; then
    echo "Error signing certificate."; exit 1
fi

echo
echo "========================================"
echo " Certificate Generation Successful! "
echo "========================================"
echo "CA Certificate:     $CA_CERT_PATH"
if [ "$NEW_CA_GENERATED" == "true" ]; then
    echo "CA Private Key:     $CA_KEY_PATH (Newly generated)"
fi
echo "CA Serial File:     $CA_SERIAL_PATH"
echo "----------------------------------------"
echo "Generated Certificate: $CERT_PATH"
echo "Generated Private Key: $CERT_KEY_PATH"
echo "Generated CSR:         $CERT_CSR_PATH"
echo "----------------------------------------"
echo
echo "You can verify the certificate's details with:"
echo "openssl x509 -in \"$CERT_PATH\" -noout -text"
echo
echo "And verify the certificate against the CA with:"
echo "openssl verify -CAfile \"$CA_CERT_PATH\" \"$CERT_PATH\""
echo

exit 0
