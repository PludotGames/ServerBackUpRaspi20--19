#!/bin/bash

# ============================================
#   LAMP Stack Setup Script
#   Installs: Apache2, MariaDB, PHP/SQL
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Must run as root
[ "$EUID" -ne 0 ] && error "Please run as root (sudo)"

# ── 1. Update system ──────────────────────────────────────────────────────────
log "Updating package lists..."
apt-get update -y

# ── 2. Install packages ───────────────────────────────────────────────────────
log "Installing Apache2, MariaDB, PHP & utilities..."
apt-get install -y \
    apache2 \
    mariadb-server \
    php \
    php-mysql \
    libapache2-mod-php \
    git \
    curl

# ── 3. Start & enable services ────────────────────────────────────────────────
log "Starting Apache2..."
systemctl enable --now apache2

log "Starting MariaDB..."
systemctl enable --now mariadb

# ── 4. Secure MariaDB (mysql_secure_installation equivalent) ──────────────────
log "Securing MariaDB installation..."

DB_ROOT_PASS="stemdb"

# On a fresh install MariaDB uses unix_socket auth — run as system root with no password
mysql <<EOF
-- Switch root to password authentication and set the password
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASS}');

-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Disallow root login remotely
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- NOTE: Privilege tables are NOT reloaded (as per config: Reload = n)
-- They will be reloaded on next MariaDB restart
FLUSH PRIVILEGES;
EOF

log "MariaDB secured. Root password set to: ${DB_ROOT_PASS}"
warn "Privilege tables will reload on next MariaDB restart (as configured)."

# ── 5. Clone repo into /var/www/html/ ─────────────────────────────────────────
# TODO: Replace the placeholder below with the actual repository URL
GIT_REPO="https://github.com/YOUR_USERNAME/YOUR_REPO.git"   # <── REPLACE THIS
DEPLOY_DIR="/var/www/html"

log "Cloning repository into ${DEPLOY_DIR}..."

# Remove default Apache index if present
rm -f "${DEPLOY_DIR}/index.html"

git clone "${GIT_REPO}" "${DEPLOY_DIR}/"

# Fix ownership so Apache can serve the files
chown -R www-data:www-data "${DEPLOY_DIR}"
chmod -R 755 "${DEPLOY_DIR}"

# ── 6. Restart Apache ─────────────────────────────────────────────────────────
log "Restarting Apache2..."
systemctl restart apache2

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "  Apache2  : ${GREEN}running${NC}"
echo -e "  MariaDB  : ${GREEN}running${NC}  (root pass: ${YELLOW}${DB_ROOT_PASS}${NC})"
echo -e "  Web root : ${YELLOW}${DEPLOY_DIR}${NC}"
echo ""
warn "Remember to replace the GIT_REPO variable with your actual repo URL!"
