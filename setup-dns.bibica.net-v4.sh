#!/bin/bash

clear

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

print_centered() {
    local text="$1"
    local width=$(tput cols)
    local padding=$(( (width - ${#text}) / 2 ))
    printf "%${padding}s%s\n" "" "$text"
}

print_separator() {
    local width=$(tput cols)
    printf '%*s\n' "$width" '' | tr ' ' '='
}

if [ "$EUID" -ne 0 ]; then 
    print_error "Please run this script with root privileges (sudo)"
    exit 1
fi

ENV_FILE="/home/.env"

validate_domain() {
    local domain=$1
    [[ ${#domain} -le 253 ]] && \
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && \
    [[ ! "$domain" =~ \.\. ]]
}

validate_api_token() {
    [[ ${#1} -ge 40 ]]
}

verify_cloudflare_token() {
    local token=$1
    print_info "Verifying Cloudflare API Token..."
    
    local response=$(curl -s --connect-timeout 10 -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    if [[ "$response" == *"\"success\":true"* ]] && [[ "$response" == *"This API Token is valid and active"* ]]; then
        return 0
    else
        return 1
    fi
}

load_saved_token() {
    if [ -f "$ENV_FILE" ]; then
        local token=$(grep "^CLOUDFLARE_API_TOKEN=" "$ENV_FILE" | cut -d'=' -f2)
        if [ -n "$token" ] && [ "$token" != "XXXXXXXXXXXXXXXXXX" ]; then
            echo "$token"
        fi
    fi
}

load_saved_domain() {
    if [ -f "$ENV_FILE" ]; then
        local domain=$(grep "^CERTBOT_DOMAINS=" "$ENV_FILE" | cut -d'=' -f2)
        if [ -n "$domain" ]; then
            echo "$domain"
        fi
    fi
}

save_token() {
    local token=$1
    if [ -f "$ENV_FILE" ]; then
        sed -i "s|^CLOUDFLARE_API_TOKEN=.*|CLOUDFLARE_API_TOKEN=$token|g" "$ENV_FILE"
    fi
}

create_env_file() {
    local domain=$1
    local email=$2
    local token=$3
    
    print_info "Creating .env file..."
    
    cat > "$ENV_FILE" << EOF
CLOUDFLARE_API_TOKEN=$token
CERTBOT_EMAIL=$email
CERTBOT_DOMAINS=$domain
EOF
    
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    
    if [ $? -eq 0 ]; then
        print_success ".env file created successfully with secure permissions"
    else
        print_error "Failed to create .env file"
        exit 1
    fi
}

update_env_file() {
    local domain=$1
    local email=$2
    local token=$3

    sed -i "s|^CLOUDFLARE_API_TOKEN=.*|CLOUDFLARE_API_TOKEN=$token|g" "$ENV_FILE"
    sed -i "s|^CERTBOT_EMAIL=.*|CERTBOT_EMAIL=$email|g" "$ENV_FILE"
    sed -i "s|^CERTBOT_DOMAINS=.*|CERTBOT_DOMAINS=$domain|g" "$ENV_FILE"
    
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    
}

remove_existing_cron() {
    local cron_pattern="docker start certbot"
    print_info "Checking for existing cron jobs..."
    
    crontab -l 2>/dev/null | grep -v "$cron_pattern" | crontab - 2>/dev/null
    
    if [ $? -eq 0 ]; then
        print_success "Removed any existing certbot cron jobs"
    fi
}

add_certbot_cron() {
    print_info "Setting up certbot renewal cron job..."
    
    remove_existing_cron
    
    (crontab -l 2>/dev/null; echo "0 3 * * * docker start certbot") | crontab -
    
    if [ $? -eq 0 ]; then
        print_success "Certbot cron job added successfully (runs daily at 3:00 AM)"
    else
        print_error "Failed to add certbot cron job"
    fi
}

print_separator
print_centered "Public DNS Service Installation"
print_centered "Mosdns-x PR (Privacy & Resilience)"
print_centered "with Certbot & Persistent Redis"
print_separator
echo ""

# Get domain with saved domain detection
SAVED_DOMAIN=$(load_saved_domain)
DOMAIN=""

if [ -n "$SAVED_DOMAIN" ]; then
    print_info "Found saved domain: $SAVED_DOMAIN"
    
    while true; do
        read -p "Do you want to use the saved domain? (Y/n): " USE_SAVED_DOMAIN
        USE_SAVED_DOMAIN=${USE_SAVED_DOMAIN:-Y}
        
        if [[ "$USE_SAVED_DOMAIN" =~ ^[Yy]$ ]]; then
            DOMAIN="$SAVED_DOMAIN"
            print_success "Using saved domain: $DOMAIN"
            break
        elif [[ "$USE_SAVED_DOMAIN" =~ ^[Nn]$ ]]; then
            break
        else
            print_error "Invalid input. Please enter Y or N."
        fi
    done
fi

if [ -z "$DOMAIN" ]; then
    echo ""
    while true; do
        read -p "Enter the domain you want to use (e.g., dns.bibica.net): " DOMAIN
        
        if validate_domain "$DOMAIN"; then
            print_success "Valid domain: $DOMAIN"
            break
        else
            print_error "Invalid domain. Please try again."
        fi
    done
fi

# Auto-generate email from domain
EMAIL="admin@$DOMAIN"
print_info "SSL certificate email: $EMAIL"

# Get API Token with saved token detection
echo ""
print_separator
print_centered "Cloudflare API Token"
print_separator
echo ""

SAVED_TOKEN=$(load_saved_token)
API_TOKEN=""

if [ -n "$SAVED_TOKEN" ]; then
    print_info "Found saved Cloudflare API Token."
    
    while true; do
        read -p "Do you want to use the saved token? (Y/n): " USE_SAVED
        USE_SAVED=${USE_SAVED:-Y}
        
        if [[ "$USE_SAVED" =~ ^[Yy]$ ]]; then
            if verify_cloudflare_token "$SAVED_TOKEN"; then
                API_TOKEN="$SAVED_TOKEN"
                print_success "Using saved API Token."
                break
            else
                print_error "Saved token is invalid or inactive. Please enter a new one."
                break
            fi
        elif [[ "$USE_SAVED" =~ ^[Nn]$ ]]; then
            break
        else
            print_error "Invalid input. Please enter Y or N."
        fi
    done
fi

if [ -z "$API_TOKEN" ]; then
    echo ""
    echo "If you don't have an API Token yet, follow these steps:"
    echo ""
    echo "  1. Access: https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. Click 'Create Token'"
    echo "  3. Choose Template: 'Edit zone DNS'"
    echo "  4. Click 'Continue to summary' → 'Create Token'"
    echo "  5. Copy the token"
    echo ""
    echo "API Token usually looks like: Aq9KZsM0yXHfV3BNe4cWb2tEPLoRrG8iJdYUh1m7F5O6k"
    echo ""
    
    while true; do
        read -p "Enter Cloudflare API Token: " API_TOKEN
        
        if validate_api_token "$API_TOKEN"; then
            if verify_cloudflare_token "$API_TOKEN"; then
                print_success "API Token is valid and active."
                break
            else
                print_error "API Token is incorrect or inactive. Please check your token and permissions."
            fi
        else
            print_error "Invalid API Token format (must be at least 40 characters). Please try again."
        fi
    done
fi

echo ""
print_info "Starting installation process..."
echo ""

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh > /dev/null 2>&1
    sh get-docker.sh > /dev/null 2>&1
    rm get-docker.sh
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1
fi

# Download project
cd /home || exit 1

curl -L https://github.com/bibicadotnet/dns.bibica.net.v4/archive/HEAD.tar.gz 2>/dev/null \
| tar xz --strip-components=1 \
&& rm -f LICENSE README.md \
&& chmod +x *.sh

if [ $? -ne 0 ]; then
    print_error "Unable to download project. Please check your internet connection."
    exit 1
fi

# Create or update .env file
if [ -f "$ENV_FILE" ]; then
    update_env_file "$DOMAIN" "$EMAIL" "$API_TOKEN"
else
    create_env_file "$DOMAIN" "$EMAIL" "$API_TOKEN"
fi

# Configure mosdns-x config
if [ -f /home/mosdns-x/config/config.yaml ]; then
    sed -i "s/dns\.bibica\.net/$DOMAIN/g" /home/mosdns-x/config/config.yaml
else
    print_error "Mosdns-x config file not found"
    exit 1
fi

# Calculate Redis memory
TOTAL_RAM_MB=$(free -m | awk 'NR==2 {print $2}')
REDIS_MEMORY_MB=$((TOTAL_RAM_MB / 2))

if [ -f /home/compose.yml ]; then
    sed -i "s/--maxmemory [0-9]*mb/--maxmemory ${REDIS_MEMORY_MB}mb/g" /home/compose.yml
fi

# Backup old SSL certificates if domain changed
if [ -n "$SAVED_DOMAIN" ] && [ "$DOMAIN" != "$SAVED_DOMAIN" ] && [ -d "/home/certbot/letsencrypt/live/$SAVED_DOMAIN" ]; then
    BACKUP_DIR="/home/certbot/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r /home/certbot/letsencrypt/live/$SAVED_DOMAIN "$BACKUP_DIR/"
    print_success "Old SSL certificates backed up to: $BACKUP_DIR"
fi

# Fix permissions for Docker volumes
print_info "Fixing Docker volumes permissions..."

if [ -d "/home/redis-data" ]; then
    chown -R 999:1000 /home/redis-data
fi

if [ -d "/home/certbot" ]; then
    chown -R 1000:1000 /home/certbot
fi

print_success "Docker volumes permissions fixed"

# Start Docker services
cd /home || exit 1
docker compose up -d --build --remove-orphans --force-recreate > /dev/null 2>&1

if [ $? -ne 0 ]; then
    print_error "Failed to initialize Docker. Please check for errors."
    exit 1
fi

# Setup ad-blocking cron if script exists
if [ -f /home/setup-cron-mosdns-block-allow.sh ]; then
    /home/setup-cron-mosdns-block-allow.sh > /dev/null 2>&1
fi

# Add certbot renewal cron job
remove_existing_cron > /dev/null 2>&1
(crontab -l 2>/dev/null; echo "0 3 * * * docker start certbot") | crontab - > /dev/null 2>&1

# Wait for SSL certificates
CERT_PATH="/home/certbot/letsencrypt/live/$DOMAIN"
MAX_WAIT=120
WAITED=0

print_info "Waiting for SSL certificates to be generated..."

while [ $WAITED -lt $MAX_WAIT ]; do
    if [ -f "$CERT_PATH/cert.pem" ] && [ -f "$CERT_PATH/privkey.pem" ] && [ -f "$CERT_PATH/fullchain.pem" ]; then
        print_success "SSL certificates generated successfully!"
        break
    fi
    
    sleep 5
    WAITED=$((WAITED + 5))
    
    if [ $WAITED -eq $MAX_WAIT ]; then
        print_warning "SSL certificates not generated after 120 seconds. Please check logs: cat /home/certbot/logs/letsencrypt.log"
    fi
done

SERVER_IP=$(curl -s https://api.ipify.org)

echo ""
print_separator
print_centered "Installation Successful!"
print_separator
echo ""
print_success "Mosdns-x PR with Certbot & Persistent Redis has been installed successfully!"
echo ""
print_separator
print_centered "DNS Configuration"
print_separator
echo ""
print_warning "Please point your DNS record in Cloudflare:"
echo "  - Name: $DOMAIN"
echo "  - Type: A"
echo "  - Value: $SERVER_IP"
echo "  - Proxy status: DNS only (grey cloud)"
echo ""
print_separator
print_centered "Usage Information"
print_separator
echo ""
cat << EOF

  DNS IPv4:                  $SERVER_IP
  DNS-over-HTTPS (DoH):      https://$DOMAIN/dns-query
  DNS-over-TLS (DoT):        tls://$DOMAIN
  DNS-over-HTTP/3 (DoH3):    h3://$DOMAIN/dns-query
  DNS-over-QUIC (DoQ):       quic://$DOMAIN

  SSL Certificates:          /home/certbot/letsencrypt/live/$DOMAIN/
  Redis Max Memory Limit:    ${REDIS_MEMORY_MB} MB

  Ad-blocking:               Updates daily at 2:00 AM via cron
  SSL-renewal:               Updates daily at 3:00 AM via cron
  Restart service:           cd /home && docker compose restart

EOF
echo ""
print_success "Installation complete!"
echo ""
