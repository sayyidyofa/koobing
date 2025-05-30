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
    # ca.srl is not removed as it's stateful for the CA
}
trap cleanup EXIT # Register cleanup function to run on script exit

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
# Arguments:
# 1: Common Name (CN) for the certificate subject
# 2: Extended Key Usage (EKU) string (e.g., "serverAuth, clientAuth")
# 3: Comma-separated DNS SANs string
# 4: Comma-separated IP SANs string
# 5: Email address (for human client certs, populates Subject E and rfc822Name SAN)
generate_openssl_config() {
    local cn="$1"
    local eku="$2"
    local sans_dns_str="$3"
    local sans_ip_str="$4"
    local email_san="$5"

    echo "Generating OpenSSL configuration file ($OPENSSL_CNF)..."

    # Base configuration for the [req] section
    cat > "$OPENSSL_CNF" <<-EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no  # Do not prompt for Subject DN fields, use values below

[ req_distinguished_name ]
CN = $cn
EOF

    # Add EmailAddress to the Subject DN if an email is provided (for human client certs)
    if [ -n "$email_san" ]; then
        echo "emailAddress = $email_san" >> "$OPENSSL_CNF"
    fi

    # Configuration for certificate extensions ([v3_req] and [alt_names])
    cat >> "$OPENSSL_CNF" <<-EOF

[ v3_req ]
basicConstraints = CA:FALSE # This is an end-entity certificate
keyUsage = nonRepudiation, digitalSignature, keyEncipherment # Standard key usage
extendedKeyUsage = $eku # Set the EKU based on certificate purpose
subjectAltName = @alt_names # Refer to the alt_names section for SANs

[ alt_names ]
# This section will be populated with DNS, IP, and email SANs
EOF

    local san_idx=1 # Index for SAN entries

    # Add DNS SANs to the config if provided
    if [ -n "$sans_dns_str" ]; then
        IFS=',' read -r -a dns_array <<< "$sans_dns_str" # Split string into array
        for dns_name in "${dns_array[@]}"; do
            dns_name=$(echo "$dns_name" | xargs) # Trim whitespace
            if [ -n "$dns_name" ]; then
                echo "DNS.$san_idx = $dns_name" >> "$OPENSSL_CNF"
                san_idx=$((san_idx + 1))
            fi
        done
    fi

    # Add IP SANs to the config if provided
    if [ -n "$sans_ip_str" ]; then
        IFS=',' read -r -a ip_array <<< "$sans_ip_str" # Split string into array
        for ip_addr in "${ip_array[@]}"; do
            ip_addr=$(echo "$ip_addr" | xargs) # Trim whitespace
            if [ -n "$ip_addr" ]; then
                echo "IP.$san_idx = $ip_addr" >> "$OPENSSL_CNF"
                san_idx=$((san_idx + 1))
            fi
        done
    fi

    # Add rfc822Name (email) SAN if an email is provided
    if [ -n "$email_san" ]; then
        echo "email.$san_idx = $email_san" >> "$OPENSSL_CNF"
        # OpenSSL interprets 'email.X' in [alt_names] as an rfc822Name SAN
    fi

    echo "OpenSSL configuration generated:"
    cat "$OPENSSL_CNF" # Display the generated config for review/debugging
    echo "---"
}

# --- Main Script Logic ---

echo "========================================"
echo " Interactive TLS Certificate Generator "
echo "========================================"
echo

# Check if OpenSSL is installed
if ! command -v openssl &> /dev/null; then
    echo "Error: openssl command not found. Please install OpenSSL and ensure it's in your PATH."
    exit 1
fi

# CA Certificate Handling
CA_CERT_PATH=""
CA_KEY_PATH=""
CA_SERIAL_PATH="ca.srl" # Default name for the CA's serial number file

if prompt_yes_no "Do you have an existing CA certificate and key?"; then
    # User has an existing CA
    while true; do
        prompt_input "Enter path to CA certificate file (e.g., ca.crt)" "" CA_CERT_PATH
        if [ -f "$CA_CERT_PATH" ]; then break; else echo "File not found: $CA_CERT_PATH. Please try again."; fi
    done
    while true; do
        prompt_input "Enter path to CA private key file (e.g., ca.key)" "" CA_KEY_PATH
        if [ -f "$CA_KEY_PATH" ]; then break; else echo "File not found: $CA_KEY_PATH. Please try again."; fi
    done
    prompt_input "Enter path to CA serial file (e.g., ca.srl, will be created if it doesn't exist)" "$CA_SERIAL_PATH" CA_SERIAL_PATH
else
    # Generate a new CA
    echo "Generating a new CA..."
    CA_CERT_PATH="ca.crt" # Default filename for new CA cert
    CA_KEY_PATH="ca.key"   # Default filename for new CA key

    prompt_input "Enter Common Name (CN) for the new CA" "My Local CA" CA_CN
    prompt_input "Enter Organization (O) for the new CA" "My Organization" CA_O
    prompt_input "Enter Country (C) for the new CA (2-letter code)" "US" CA_C

    echo "Generating CA private key ($CA_KEY_PATH)..."
    # Generate a 4096-bit RSA key for the CA
    if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$CA_KEY_PATH"; then
        echo "Error generating CA private key."
        exit 1
    fi
    chmod 400 "$CA_KEY_PATH" # Restrict permissions on the CA key

    echo "Generating CA certificate ($CA_CERT_PATH, valid for $DEFAULT_CA_VALIDITY_DAYS days)..."
    SUBJECT_DN="/CN=$CA_CN/O=$CA_O/C=$CA_C" # Construct the Subject DN string
    # Generate a self-signed x509 certificate for the CA
    # -addext specifies X.509 v3 extensions critical for a CA
    if ! openssl req -x509 -new -nodes -key "$CA_KEY_PATH" -sha256 -days "$DEFAULT_CA_VALIDITY_DAYS" -out "$CA_CERT_PATH" -subj "$SUBJECT_DN" \
        -addext "basicConstraints = critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage = critical,keyCertSign,cRLSign"; then
        echo "Error generating CA certificate."
        exit 1
    fi
    echo "New CA generated: $CA_CERT_PATH, $CA_KEY_PATH"
    # The serial file (CA_SERIAL_PATH) will be created by OpenSSL during the first signing operation if it doesn't exist.
fi
echo # Newline for readability

# Certificate Purpose Selection
echo "Select certificate purpose:"
echo "1) SSL Server Authentication only (for web servers, etc.)"
echo "2) mTLS (Server Authentication + Client Authentication)"
echo "3) Client Authentication only (for client-side identification)"
CERT_PURPOSE_CHOICE=""
while [[ ! "$CERT_PURPOSE_CHOICE" =~ ^[1-3]$ ]]; do # Loop until valid input
    prompt_input "Enter your choice (1-3)" "1" CERT_PURPOSE_CHOICE
done

EKU="" # Extended Key Usage string
case "$CERT_PURPOSE_CHOICE" in
    1) EKU="serverAuth";;
    2) EKU="serverAuth, clientAuth";;
    3) EKU="clientAuth";;
esac
echo

# Algorithm Selection for the new certificate's key
echo "Select signing algorithm for the new certificate's key:"
echo "1) RSA 2048 bits"
echo "2) RSA 4096 bits"
echo "3) ECDSA prime256v1 (NIST P-256)"
echo "4) ECDSA secp384r1 (NIST P-384)"
ALGO_CHOICE=""
while [[ ! "$ALGO_CHOICE" =~ ^[1-4]$ ]]; do # Loop until valid input
    prompt_input "Enter your choice (1-4)" "1" ALGO_CHOICE
done

KEY_TYPE=""       # RSA or EC
KEY_PARAM=""      # Bits for RSA, curve name for EC
KEY_GEN_CMD=""    # OpenSSL command for key generation
case "$ALGO_CHOICE" in
    1) KEY_TYPE="RSA"; KEY_PARAM="2048"; KEY_GEN_CMD="openssl genrsa -out";;
    2) KEY_TYPE="RSA"; KEY_PARAM="4096"; KEY_GEN_CMD="openssl genrsa -out";;
    3) KEY_TYPE="EC"; KEY_PARAM="prime256v1"; KEY_GEN_CMD="openssl ecparam -name $KEY_PARAM -genkey -noout -out";;
    4) KEY_TYPE="EC"; KEY_PARAM="secp384r1"; KEY_GEN_CMD="openssl ecparam -name $KEY_PARAM -genkey -noout -out";;
esac
echo

# Certificate Details (CN, SANs, Email)
CERT_CN=""
DNS_SANS=""
IP_SANS=""
USER_EMAIL=""         # For human client certs (Subject E and rfc822Name SAN)
IS_MACHINE_CLIENT=""  # Flag: "yes" if client cert is for a machine, "no" for human

# Prompt for a prefix for output filenames to keep them organized
OUTPUT_PREFIX=""
while [ -z "$OUTPUT_PREFIX" ]; do
    prompt_input "Enter a prefix for output file names (e.g., my_server, client_john)" "" OUTPUT_PREFIX
    if [ -z "$OUTPUT_PREFIX" ]; then
        echo "Error: Output prefix cannot be empty."
    fi
done

CERT_KEY_PATH="${OUTPUT_PREFIX}.key" # Filename for the certificate's private key
CERT_CSR_PATH="${OUTPUT_PREFIX}.csr" # Filename for the Certificate Signing Request
CERT_PATH="${OUTPUT_PREFIX}.crt"     # Filename for the signed certificate

if [ "$CERT_PURPOSE_CHOICE" -eq 3 ]; then # Client Authentication only
    if prompt_yes_no "Is this client certificate for a machine?"; then
        IS_MACHINE_CLIENT="yes"
        # EKU is already "clientAuth"
        prompt_input "Enter Common Name (CN) for the machine client certificate" "client.internal.example.com" CERT_CN
        prompt_input "Enter comma-separated DNS SANs (e.g., app1.internal,app2.internal)" "" DNS_SANS
        prompt_input "Enter comma-separated IP SANs (e.g., 10.0.0.5,10.0.0.6)" "" IP_SANS_USER
        # Add 127.0.0.1 to IP SANs for machine clients
        if [ -n "$IP_SANS_USER" ]; then
            IP_SANS="$IP_SANS_USER,127.0.0.1"
        else
            IP_SANS="127.0.0.1" # Default to 127.0.0.1 if no other IPs are specified
        fi
        # Remove duplicate IPs that might arise from adding 127.0.0.1
        IP_SANS=$(echo "$IP_SANS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    else # Human client
        IS_MACHINE_CLIENT="no"
        EKU="clientAuth, emailProtection" # Add emailProtection EKU for human clients
        prompt_input "Enter Common Name (CN) for the human client certificate (e.g., John Doe)" "" CERT_CN
        prompt_input "Enter Email address for the human client (for Subject E and rfc822Name SAN)" "" USER_EMAIL
        # DNS/IP SANs are less common for human client certs focused on email, so not prompted here for simplicity.
    fi
else # Server Authentication or mTLS
    prompt_input "Enter Common Name (CN) for the certificate (e.g., server.example.com)" "" CERT_CN
    prompt_input "Enter comma-separated DNS SANs (e.g., www.example.com,api.example.com)" "$CERT_CN" DNS_SANS # Default DNS SAN to CN
    prompt_input "Enter comma-separated IP SANs (e.g., 192.168.1.100)" "" IP_SANS_USER
    # Add 127.0.0.1 to IP SANs for server certs
    if [ -n "$IP_SANS_USER" ]; then
        IP_SANS="$IP_SANS_USER,127.0.0.1"
    else
        # If CN is an IP, it could be added here, but for now, just 127.0.0.1 if no other IPs.
        IP_SANS="127.0.0.1"
    fi
    IP_SANS=$(echo "$IP_SANS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//') # Remove duplicates
fi
echo

# Certificate Validity Period
prompt_input "Enter certificate validity period in days" "$DEFAULT_CERT_VALIDITY_DAYS" CERT_VALIDITY_DAYS
if ! [[ "$CERT_VALIDITY_DAYS" =~ ^[0-9]+$ ]] || [ "$CERT_VALIDITY_DAYS" -le 0 ]; then
    echo "Invalid validity period. Using default: $DEFAULT_CERT_VALIDITY_DAYS days."
    CERT_VALIDITY_DAYS=$DEFAULT_CERT_VALIDITY_DAYS
fi
echo

# --- Generation Steps ---

# 1. Generate Private Key for the new certificate
echo "Generating private key ($CERT_KEY_PATH) using $KEY_TYPE $KEY_PARAM..."
if [ "$KEY_TYPE" == "RSA" ]; then
    if ! $KEY_GEN_CMD "$CERT_KEY_PATH" "$KEY_PARAM"; then
        echo "Error generating private key for certificate."
        exit 1
    fi
else # EC key generation
    if ! $KEY_GEN_CMD "$CERT_KEY_PATH"; then
        echo "Error generating private key for certificate."
        exit 1
    fi
fi
chmod 400 "$CERT_KEY_PATH" # Restrict permissions
echo "Private key generated: $CERT_KEY_PATH"
echo

# 2. Generate CSR (Certificate Signing Request)
echo "Generating CSR ($CERT_CSR_PATH)..."
# Construct the Subject DN for the CSR.
# For human clients, include the email address in the Subject's E field.
# Other details like SANs and EKUs will be applied during signing via the extfile.
CSR_SUBJ_STR="/CN=$CERT_CN"
if [ "$IS_MACHINE_CLIENT" == "no" ] && [ -n "$USER_EMAIL" ]; then # If human client and email is provided
    CSR_SUBJ_STR="$CSR_SUBJ_STR/emailAddress=$USER_EMAIL"
fi

if ! openssl req -new -key "$CERT_KEY_PATH" -out "$CERT_CSR_PATH" -subj "$CSR_SUBJ_STR"; then
    echo "Error generating CSR."
    exit 1
fi
echo "CSR generated: $CERT_CSR_PATH"
echo

# 3. Prepare OpenSSL config file for signing (includes SANs, EKU, etc.)
generate_openssl_config "$CERT_CN" "$EKU" "$DNS_SANS" "$IP_SANS" "$USER_EMAIL"

# 4. Sign the certificate using the CA
echo "Signing the certificate ($CERT_PATH) with CA: $CA_CERT_PATH..."
echo "Using CA key: $CA_KEY_PATH"
echo "Using CA serial file: $CA_SERIAL_PATH (will be created if it doesn't exist)"
echo "Certificate will be valid for $CERT_VALIDITY_DAYS days."

# Ensure the directory for the CA serial file exists if a path is specified
SERIAL_DIR=$(dirname "$CA_SERIAL_PATH")
if [ ! -d "$SERIAL_DIR" ]; then
    mkdir -p "$SERIAL_DIR" # Create directory if it doesn't exist
fi

# Sign the CSR with the CA.
# -CAcreateserial: creates the serial number file (e.g., ca.srl) if it doesn't exist.
# -extfile: specifies the OpenSSL configuration file.
# -extensions: specifies the section in the config file containing extensions to apply.
if ! openssl x509 -req -in "$CERT_CSR_PATH" \
    -CA "$CA_CERT_PATH" -CAkey "$CA_KEY_PATH" \
    -CAserial "$CA_SERIAL_PATH" -CAcreateserial \
    -out "$CERT_PATH" -days "$CERT_VALIDITY_DAYS" -sha256 \
    -extfile "$OPENSSL_CNF" -extensions v3_req; then
    echo "Error signing certificate."
    echo "Possible issues:"
    echo " - CA key might be password protected (this script assumes not)."
    echo " - Incorrect paths for CA cert/key."
    echo " - Check the contents of $OPENSSL_CNF for correctness."
    exit 1
fi

echo
echo "========================================"
echo " Certificate Generation Successful! "
echo "========================================"
echo "CA Certificate:     $CA_CERT_PATH"
# Only show CA private key path if it was newly generated by this script (default name)
if [ -f "$CA_KEY_PATH" ] && [[ "$CA_CERT_PATH" == "ca.crt" ]] && [[ "$CA_KEY_PATH" == "ca.key" ]]; then
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

# Cleanup is handled by the 'trap cleanup EXIT' command at the beginning.
exit 0
