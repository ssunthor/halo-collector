#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/data-collector

# --- Helper Function: Validate IP in CIDR ---
check_in_range() {
    local ip=$1
    local cidr=$2
    local net=$(echo $cidr | cut -d/ -f1)
    local mask=$(echo $cidr | cut -d/ -f2)
    res=$(awk -v ip="$ip" -v net="$net" -v mask="$mask" '
        function ip2int(ip) {
            split(ip, a, ".");
            return (a[1] * 16777216) + (a[2] * 65536) + (a[3] * 256) + a[4];
        }
        BEGIN {
            m = 4294967295 - (2^(32 - mask) - 1);
            if (and(ip2int(ip), m) == and(ip2int(net), m)) print "1";
            else print "0";
        }' 2>/dev/null)
    [[ "$res" == "1" ]]
}

# ==========================================
# PHASE 0: Pre-flight naming check
# ==========================================
# If eth0 doesn't exist, we must fix GRUB and reboot before anything else.
if ! ip link show eth0 > /dev/null 2>&1; then
    echo "Preparing system interface naming conventions..."
    sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /etc/default/grub
    # Also handle cases where there might already be parameters
    if ! grep -q "net.ifnames=0" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/' /etc/default/grub
    fi
    update-grub
    
    whiptail --title "System Initialization" --msgbox "The appliance needs to adjust network interface naming (eth0/eth1).\n\nThe system will reboot now and resume setup automatically." 10 60
    reboot
    exit 0
fi

# ==========================================
# PHASE 1: Identity, Network, & Connectivity
# ==========================================
if [ ! -f /opt/data-collector/.phase1_done ]; then

    whiptail --title "Defense Halo Collector v0.5" --msgbox "Welcome to the Setup Wizard.\n\nPress OK to begin Identity and Network configuration." 10 60

    # --- 1. Identity ---
    HN=$(whiptail --title "System Identity" --inputbox "Enter Hostname:" 10 60 "halo-collector" 3>&1 1>&2 2>&3)
    SDOMAIN=$(whiptail --title "System Identity" --inputbox "Enter DNS Search Domain:" 10 60 "internal.corp" 3>&1 1>&2 2>&3)

    # --- 2. Security (Password Change) ---
    while true; do
        ADMIN_PASS=$(whiptail --title "Security Setup" --passwordbox "Set a new password for the 'haloadmin' account:" 10 60 3>&1 1>&2 2>&3)
        if [ -z "$ADMIN_PASS" ]; then
            whiptail --title "Error" --msgbox "Password cannot be empty. Please try again." 10 60
            continue
        fi

        ADMIN_PASS_CONFIRM=$(whiptail --title "Security Setup" --passwordbox "Confirm the new password:" 10 60 3>&1 1>&2 2>&3)
        
        if [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ]; then
            # Apply the password change to the system
            echo "haloadmin:$ADMIN_PASS" | chpasswd
            break
        else
            whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 10 60
        fi
    done

    # --- 3. Interface eth0 (Management) ---
    ETH0_IP=$(whiptail --title "eth0 (Management)" --inputbox "Enter eth0 IP/CIDR (e.g., 192.168.1.10/24):" 10 60 3>&1 1>&2 2>&3)
    ETH0_GW=$(whiptail --title "eth0 (Management)" --inputbox "Enter eth0 Default Gateway:" 10 60 3>&1 1>&2 2>&3)

    until check_in_range "$ETH0_GW" "$ETH0_IP"; do
        whiptail --title "Error" --msgbox "Gateway $ETH0_GW is outside of the $ETH0_IP range." 10 60
        ETH0_GW=$(whiptail --title "eth0 (Management)" --inputbox "Re-enter eth0 Default Gateway:" 10 60 3>&1 1>&2 2>&3)
    done

    # --- 4. Interface eth1 (Data) ---
    ETH1_IP=$(whiptail --title "eth1 (Data/Backend)" --inputbox "Enter eth1 IP/CIDR (e.g., 10.10.50.10/24):" 10 60 3>&1 1>&2 2>&3)
    ETH1_GW=$(whiptail --title "eth1 (Data/Backend)" --inputbox "Enter eth1 Backend Gateway:" 10 60 3>&1 1>&2 2>&3)

    until check_in_range "$ETH1_GW" "$ETH1_IP"; do
        whiptail --title "Error" --msgbox "Backend Gateway $ETH1_GW is outside of the $ETH1_IP range." 10 60
        ETH1_GW=$(whiptail --title "eth1 (Data/Backend)" --inputbox "Re-enter eth1 Backend Gateway:" 10 60 3>&1 1>&2 2>&3)
    done

    # --- 5. DNS & Kafka ---
    DNS1=$(whiptail --title "DNS" --inputbox "Enter Primary DNS:" 10 60 "8.8.8.8" 3>&1 1>&2 2>&3)
    DNS2=$(whiptail --title "DNS" --inputbox "Enter Secondary DNS:" 10 60 "8.8.4.4" 3>&1 1>&2 2>&3)

    # --- Apply Identity ---
    hostnamectl set-hostname "$HN"
    echo "127.0.1.1 $HN" >> /etc/hosts
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi

    # --- Apply Netplan ---
    whiptail --title "Applying Network" --infobox "Applying Netplan configuration to eth0 and eth1..." 8 60
    rm /etc/netplan/* -f
    tee /etc/netplan/01-netcfg.yaml > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: [$ETH0_IP]
      routes:
        - to: default
          via: $ETH0_GW
      nameservers:
        search: [$SDOMAIN]
        addresses: [$DNS1, $DNS2]
    eth1:
      addresses: [$ETH1_IP]
      routes:
        - to: 10.250.104.0/24
          via: $ETH1_GW
        - to: 10.250.120.0/24
          via: $ETH1_GW
        - to: 10.250.136.0/24
          via: $ETH1_GW
        - to: 10.250.152.0/24
          via: $ETH1_GW
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
                     DEFENSE HALO COLLECTOR v0.5
----------------------------------------------------------------------
  Manage via SSH or log in locally to configure networking.
  Default login: haloadmin
EOF

        # --- Update /etc/update-motd.d/10-help-text (Dynamic Banner) ---
    tee /etc/update-motd.d/10-help-text > /dev/null <<EOF
#!/bin/sh

printf "************************************************************\n"
printf "*                                                          *\n"
printf "* DEFENSE HALO COLLECTOR v0.5                              *\n"
printf "* Data Collector                                           *\n"
printf "*                                                          *\n"
printf "************************************************************\n"
printf "\n"
printf "Config: /opt/data-collector/"
printf "\n"
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
# PHASE 2: Docker Installation
# ==========================================


if [ -f /opt/data-collector/.phase1_done ] && [ ! -f /opt/data-collector/.setup_done ]; then
  
    K_BROKERS=$(whiptail --title "Kafka" --inputbox "Enter Kafka Brokers (IP:Port):" 10 60 3>&1 1>&2 2>&3)

    # Create env for Docker
    tee /opt/data-collector/.env > /dev/null <<EOF
KAFKA_BROKERS=$K_BROKERS
EOF

    # Create Halo Collector Compose file
    tee /opt/data-collector/halo-collectors.yaml > /dev/null <<EOF
services:
  fluent-bit-rfc-5424:
    image: fluent/fluent-bit:latest
    container_name: fluent-bit-5424
    ports:
      - "514:514/udp"
    environment:
      - KAFKA_BROKERS=${K_BROKERS}
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - ./parser-rfc-5454.conf:/fluent-bit/etc/parser.conf
    restart: always

  fluent-bit-rfc-3164:
    image: fluent/fluent-bit:latest
    container_name: fluent-bit-3164
    ports:
      - "515:514/udp"
    environment:
      - KAFKA_BROKERS=${K_BROKERS}
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - ./parser-rfc-3164.conf:/fluent-bit/etc/parser.conf
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

    # Create fluent-bit configuration
    tee /opt/data-collector/fluent-bit.conf > /dev/null <<EOF
[SERVICE]
   Flush        1
   Log_Level    info
   Parsers_File /fluent-bit/etc/parser.conf

[INPUT]
   Name         syslog
   Mode         udp
   Listen       0.0.0.0
   Port         514
   Parser       custom-syslog
   Tag          syslog.raw

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
    tee /opt/data-collector/parser-rfc-5454.conf > /dev/null <<EOF
[PARSER]
   Name        custom-syslog
   Format      regex
   Regex       ^(?<message>(?:<\d+>)?(?:[A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+(?<host>\S+).*)$
EOF

    # Create fluent-bit parser rfc 3164
    tee /opt/data-collector/parser-rfc-3164.conf > /dev/null <<EOF
[PARSER]
   Name        custom-syslog
   Format      regex
   Regex       /^\<(?<pri>[0-9]+)\>(?<time>[^ ]* {1,2}[^ ]* [^ ]*) (?<host>[^ ]*) (?<ident>[a-zA-Z0-9_\/\.\-]*)(?:\[(?<pid>[0-9]+)\])?(?:[^\:]*\:)? *(?<message>.*)$/
EOF

    whiptail --title "Docker" --infobox "Installing latest Docker Engine..." 8 60
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start the stack
    cd /opt/data-collector && docker compose -f halo-collectors.yaml up -d

    touch /opt/data-collector/.setup_done
    whiptail --title "Defense Halo" --msgbox "Setup Complete.\n\nAll services are online." 10 60
fi