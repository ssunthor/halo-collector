#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/data-collector/certs

# ==========================================
# PHASE 0: Pre-flight naming check
# ==========================================
if ! ip link show eth0 > /dev/null 2>&1; then
    echo "Preparing system interface naming conventions..."
    sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /etc/default/grub
    if ! grep -q "net.ifnames=0" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/' /etc/default/grub
    fi
    update-grub
    
    whiptail --title "System Initialization" --msgbox "The appliance needs to adjust network interface naming (eth0).\n\nThe system will reboot now and resume setup automatically." 10 60
    reboot
    exit 0
fi

# ==========================================
# PHASE 1: Identity, Security, & Network Configuration
# ==========================================
if [ ! -f /opt/data-collector/.phase1_done ]; then

    whiptail --title "Defense Halo Collector v0.8" --msgbox "Welcome to the Setup Wizard.\n\nPress OK to begin Identity and Security configuration." 10 60

    # --- 1. Identity ---
    HN=$(whiptail --title "System Identity" --inputbox "Enter Hostname:" 10 60 "halo-collector" 3>&1 1>&2 2>&3)
    SDOMAIN=$(whiptail --title "System Identity" --inputbox "Enter DNS Search Domain:" 10 60 "internal.corp" 3>&1 1>&2 2>&3)

    # --- 2. Security (Password Change for haloadmin) ---
    while true; do
        ADMIN_PASS=$(whiptail --title "Security Setup" --passwordbox "Set a new password for the 'haloadmin' account:" 10 60 3>&1 1>&2 2>&3)
        if [ -z "$ADMIN_PASS" ]; then
            whiptail --title "Error" --msgbox "Password cannot be empty. Please try again." 10 60
            continue
        fi

        ADMIN_PASS_CONFIRM=$(whiptail --title "Security Setup" --passwordbox "Confirm the new password:" 10 60 3>&1 1>&2 2>&3)
        
        if [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ]; then
            echo "haloadmin:$ADMIN_PASS" | chpasswd
            break
        else
            whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 10 60
        fi
    done

    # --- Apply Identity ---
    hostnamectl set-hostname "$HN"
    echo "127.0.1.1 $HN" >> /etc/hosts
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi

    # --- Apply Netplan Configuration ---
    whiptail --title "Applying Network" --infobox "Applying static network configuration to eth0..." 8 60
    rm /etc/netplan/* -f
    tee /etc/netplan/01-netcfg.yaml > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: [100.64.1.11/24]
      routes:
        - to: default
          via: 100.64.1.254
      nameservers:
        search: [$SDOMAIN]
        addresses: [8.8.8.8, 1.1.1.1]
EOF
    chmod 600 /etc/netplan/01-netcfg.yaml
    netplan apply
    sleep 4

    # --- Connectivity Tests ---
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "No Internet (Ping 8.8.8.8 failed)." 10 60; exit 1
    fi
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "DNS Failure (google.com unreachable)." 10 60; exit 1
    fi
    if ! curl -k -m 5 -Is https://www.google.com | grep -q "HTTP/"; then
        whiptail --title "Error" --msgbox "HTTPS Failure (Port 443 blocked)." 10 60; exit 1
    fi

    # --- System Upgrades ---
    whiptail --title "Updates" --infobox "Running system upgrades..." 8 60
    apt update -y && apt upgrade -y

    # --- Update /etc/issue (Dynamic Banner) ---
    tee /etc/issue > /dev/null <<EOF
         ################# ##################### #####################     
      ################### ##################### #####################      
    #################### ##################### #####################       
   ####################  ####################  ####################        
  ########                       #######              ########             
 ########                        #######              ########             
 ########                        #######              ########             
 ########     ############       #######              ########             
 ########     ############       #######              ########             
  ########         #######       #######              ########             
   ########### ###########       #######              ########             
    ######################       #######              ########             
     #####################       #######              ########             
         #########  ######       #######              ########             


----------------------------------------------------------------------
                     DEFENSE HALO COLLECTOR v0.8
----------------------------------------------------------------------
  Manage via SSH or log in locally.
  Default login: haloadmin
EOF

    # --- Update /etc/update-motd.d/10-help-text (Dynamic Banner) ---
    tee /etc/update-motd.d/10-help-text > /dev/null <<EOF
#!/bin/sh

printf "************************************************************\n"
printf "*                                                          *\n"
printf "* DEFENSE HALO COLLECTOR v0.8                              *\n"
printf "* Data Collector                                           *\n"
printf "*                                                          *\n"
printf "************************************************************\n"
printf "\n"
printf "Config: /opt/data-collector/\n"
printf "Certs:  /opt/data-collector/certs/\n"
printf "\n"
EOF

    # --- Disk Expansion ---
    if command -v lvextend >/dev/null 2>&1 && lvdisplay | grep -q "ubuntu-lv"; then
        lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
        resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
    else
        resize2fs $(findmnt -n -o SOURCE /) || true
    fi

    touch /opt/data-collector/.phase1_done

    if [ -f /var/run/reboot-required ]; then
        whiptail --title "Reboot" --msgbox "Rebooting to apply updates. Resuming on login." 10 60
        reboot
        exit 0
    fi
fi

# ==========================================
# PHASE 2: Docker & Collector Service Setup
# ==========================================
if [ -f /opt/data-collector/.phase1_done ] && [ ! -f /opt/data-collector/.setup_done ]; then
  
    K_BROKERS=$(whiptail --title "Kafka" --inputbox "Enter Kafka bootstrap (IP:Port):" 10 60 3>&1 1>&2 2>&3)

    # --- JSON API Password Prompt ---
    while true; do
        JSON_PASS=$(whiptail --title "JSON API Authentication" --passwordbox "Set password for HTTPS JSON API ('haloapi' user):" 10 60 3>&1 1>&2 2>&3)
        if [ -z "$JSON_PASS" ]; then
            whiptail --title "Error" --msgbox "Password cannot be empty. Please try again." 10 60
            continue
        fi

        JSON_PASS_CONFIRM=$(whiptail --title "JSON API Authentication" --passwordbox "Confirm HTTPS JSON API password:" 10 60 3>&1 1>&2 2>&3)
        
        if [ "$JSON_PASS" = "$JSON_PASS_CONFIRM" ]; then
            break
        else
            whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 10 60
        fi
    done

    # --- Install Prerequisites ---
    whiptail --title "Dependencies" --infobox "Installing apache2-utils and openssl..." 8 60
    apt-get update -y && apt-get install -y apache2-utils openssl ca-certificates curl gnupg lsb-release

    # --- Generate htpasswd File ---
    htpasswd -cb /opt/data-collector/nginx.htpasswd haloapi "$JSON_PASS"
    chmod 644 /opt/data-collector/nginx.htpasswd

    # --- Generate Self-Signed Certificates (If missing) ---
    if [ ! -f /opt/data-collector/certs/server.crt ] || [ ! -f /opt/data-collector/certs/server.key ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
          -keyout /opt/data-collector/certs/server.key \
          -out /opt/data-collector/certs/server.crt \
          -subj "/CN=halo-collector" >/dev/null 2>&1
    fi

    # Create .env for Docker
    tee /opt/data-collector/.env > /dev/null <<EOF
KAFKA_BROKERS=$K_BROKERS
EOF

    # Create Nginx Proxy Configuration
    tee /opt/data-collector/nginx.conf > /dev/null <<EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    auth_basic           "Defense Halo JSON API";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://fluent-bit-json:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Create fluent-bit JSON configuration
    tee /opt/data-collector/fluent-bit-json.conf > /dev/null <<EOF
[SERVICE]
   Flush        1
   Log_Level    info

[INPUT]
   Name         http
   Host         0.0.0.0
   Port         8080

[OUTPUT]
   Name                kafka
   Match               *
   Brokers             ${K_BROKERS}
   Topics              json-input
   rdkafka.linger.ms   500
   rdkafka.compression.type lz4
EOF

    # Create fluent-bit rfc 5424 configuration
    tee /opt/data-collector/fluent-bit.conf > /dev/null <<EOF
[SERVICE]
    Flush        1
    Log_Level    info
    Parsers_File /fluent-bit/etc/parser.conf

[INPUT]
    Name         udp
    Listen       0.0.0.0
    Port         514
    Format       none
    Tag          syslog.raw

[FILTER]
    Name         parser
    Match        syslog.raw
    Key_Name     log
    Parser       syslog-5424
    Parser       syslog-3164
    Reserve_Data On

[OUTPUT]
   Name                kafka
   Match               *
   Brokers             ${K_BROKERS}
   Topics              syslog-input
   message_key_field   host
   rdkafka.linger.ms   500
   rdkafka.compression.type lz4
EOF

    # Create fluent-bit parser rfc 5454
    tee /opt/data-collector/parser.conf > /dev/null <<EOF
# RFC 5424
[PARSER]
    Name        syslog-5424
    Format      regex
    Regex       ^\<(?<pri>\d+)\>(?:(?<version>\d+)\s+)?(?<time>\d{4}-\d{2}-\d{2}T[^\s]+)\s+(?<host>[^\s]+)\s+(?<appname>[^\s]+)\s+(?<pid>[^\s]+)\s+(?<msgid>[^\s]+)(?:\s+(?<sd>\[.*?\]|-))?\s*(?<message>.*)$
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S%z
    Time_Keep   On

# RFC 3164
[PARSER]
    Name        syslog-3164
    Format      regex
    Regex       ^\<(?<pri>\d+)\>(?<time>[A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+(?<host>\S+)\s+(?<appname>[^\[\:\s]+)?(?:\[(?<pid>\d+)\])?\:\s*(?<message>.*)$
    Time_Key    time
    Time_Format %b %d %H:%M:%S
    Time_Keep   On
EOF

    # Create Docker Compose file
    tee /opt/data-collector/halo-collectors.yaml > /dev/null <<EOF
services:
  fluent-bit-syslog:
    image: fluent/fluent-bit:latest
    container_name: fluent-bit-syslog
    ports:
      - "514:514/udp"
    environment:
      - KAFKA_BROKERS=${K_BROKERS}
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - ./parser.conf:/fluent-bit/etc/parser.conf
    restart: always

  fluent-bit-json:
    image: fluent/fluent-bit:latest
    container_name: fluent-bit-json
    environment:
      - KAFKA_BROKERS=${K_BROKERS}
    volumes:
      - ./fluent-bit-json.conf:/fluent-bit/etc/fluent-bit.conf
    restart: always

  nginx-proxy:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./nginx.htpasswd:/etc/nginx/.htpasswd:ro
    depends_on:
      - fluent-bit-json
    restart: always

  goflow2:
    image: netsampler/goflow2:latest
    container_name: goflow2
    restart: always
    ports:
      - "2055:2055/udp"
    command: >
      -listen=netflow://:2055
      -format=json
      -transport=kafka
      -transport.kafka.brokers=${K_BROKERS}
      -transport.kafka.topic=netflow-input
EOF

    whiptail --title "Docker" --infobox "Installing Docker Engine..." 8 60
    mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start the stack
    cd /opt/data-collector && docker compose -f halo-collectors.yaml up -d

    touch /opt/data-collector/.setup_done
    whiptail --title "Defense Halo" --msgbox "Setup Complete.\n\nAll services are online." 10 60
fi