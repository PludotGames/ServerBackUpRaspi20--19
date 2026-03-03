#!/bin/bash

# ============================================
#   Server Restore / Clone Script
#   Restores a backup onto a fresh server:
#     - Installs Apache2, MariaDB, PHP, Python
#     - Restores MariaDB databases
#     - Restores /var/www/html
#     - Restores /pythonscripts (with fresh venv)
#     - Restores crontabs
# ============================================

set -e

# ── Config ────────────────────────────────────────────────────────────────────
DB_USER="root"
DB_PASS="stemdb"
WEBROOT="/var/www/html"
PYTHON_SCRIPTS="/pythonscripts"
VENV_NAME="dhenv"

# Path to the backup folder to restore from
# Usage: sudo ./restore.sh /var/backups/server/2024-01-15_02-00-00
BACKUP_DIR="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

# ── Checks ────────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Please run as root (sudo)"

if [ -z "${BACKUP_DIR}" ]; then
    echo -e "${RED}Usage:${NC} sudo $0 /path/to/backup/folder"
    echo ""
    echo "Available backups:"
    ls -1 /var/backups/server/ 2>/dev/null || echo "  (none found in /var/backups/server/)"
    exit 1
fi

[ -d "${BACKUP_DIR}" ] || error "Backup directory not found: ${BACKUP_DIR}"

# Verify expected backup files exist
[ -f "${BACKUP_DIR}/databases.tar.gz" ]    || error "Missing databases.tar.gz in backup"
[ -f "${BACKUP_DIR}/webroot.tar.gz" ]      || error "Missing webroot.tar.gz in backup"

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   Server Restore / Clone${NC}"
echo -e "${CYAN}============================================${NC}"
info "Restoring from: ${BACKUP_DIR}"
echo ""

# ── 1. Install packages ───────────────────────────────────────────────────────
log "Updating package lists..."
apt-get update -y

log "Installing Apache2, MariaDB, PHP, Python3 & utilities..."
apt-get install -y \
    apache2 \
    mariadb-server \
    php \
    php-mysql \
    libapache2-mod-php \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl

log "Starting and enabling services..."
systemctl enable --now apache2
systemctl enable --now mariadb

# ── 2. Secure MariaDB ─────────────────────────────────────────────────────────
log "Configuring MariaDB (setting root password, securing install)..."

mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
EOF

log "MariaDB secured. Root password: ${DB_PASS}"

# ── 3. Restore MariaDB databases ──────────────────────────────────────────────
log "Restoring MariaDB databases..."

TEMP_DB_DIR=$(mktemp -d)
tar -xzf "${BACKUP_DIR}/databases.tar.gz" -C "${TEMP_DB_DIR}"

# Use the combined all_databases dump if available
if [ -f "${TEMP_DB_DIR}/databases/all_databases.sql" ]; then
    log "  Importing all_databases.sql..."
    mysql -u"${DB_USER}" -p"${DB_PASS}" < "${TEMP_DB_DIR}/databases/all_databases.sql"
else
    # Fall back to individual database files
    for SQL_FILE in "${TEMP_DB_DIR}/databases/"*.sql; do
        DB_NAME=$(basename "${SQL_FILE}" .sql)
        log "  Importing database: ${DB_NAME}"
        mysql -u"${DB_USER}" -p"${DB_PASS}" < "${SQL_FILE}"
    done
fi

rm -rf "${TEMP_DB_DIR}"
log "Database restore complete."

# ── 4. Restore /var/www/html ──────────────────────────────────────────────────
log "Restoring web root (${WEBROOT})..."

rm -rf "${WEBROOT:?}"/*
tar -xzf "${BACKUP_DIR}/webroot.tar.gz" -C /

chown -R www-data:www-data "${WEBROOT}"
chmod -R 755 "${WEBROOT}"

log "Web root restore complete."

# ── 5. Restore /pythonscripts ─────────────────────────────────────────────────
if [ -f "${BACKUP_DIR}/pythonscripts.tar.gz" ]; then
    log "Restoring Python scripts (${PYTHON_SCRIPTS})..."

    mkdir -p "${PYTHON_SCRIPTS}"
    tar -xzf "${BACKUP_DIR}/pythonscripts.tar.gz" -C /

    # Recreate the virtual environment fresh (dhenv was excluded from backup)
    log "  Recreating Python virtual environment (${VENV_NAME})..."
    python3 -m venv "${PYTHON_SCRIPTS}/${VENV_NAME}"

    # If a requirements.txt exists, install dependencies into the new venv
    if [ -f "${PYTHON_SCRIPTS}/requirements.txt" ]; then
        log "  Installing Python dependencies from requirements.txt..."
        "${PYTHON_SCRIPTS}/${VENV_NAME}/bin/pip" install --upgrade pip -q
        "${PYTHON_SCRIPTS}/${VENV_NAME}/bin/pip" install -r "${PYTHON_SCRIPTS}/requirements.txt" -q
        log "  Dependencies installed."
    else
        warn "  No requirements.txt found — skipping pip install."
    fi

    log "Python scripts restore complete."
else
    warn "No pythonscripts.tar.gz found in backup — skipping."
fi

# ── 6. Restore crontabs ───────────────────────────────────────────────────────
if [ -f "${BACKUP_DIR}/crontabs.tar.gz" ]; then
    log "Restoring crontabs..."

    TEMP_CRON_DIR=$(mktemp -d)
    tar -xzf "${BACKUP_DIR}/crontabs.tar.gz" -C "${TEMP_CRON_DIR}"

    # System crontab
    if [ -f "${TEMP_CRON_DIR}/crontabs/etc_crontab" ]; then
        cp "${TEMP_CRON_DIR}/crontabs/etc_crontab" /etc/crontab
        log "  Restored /etc/crontab"
    fi

    # cron.d entries
    if [ -d "${TEMP_CRON_DIR}/crontabs/cron.d" ]; then
        cp -r "${TEMP_CRON_DIR}/crontabs/cron.d/." /etc/cron.d/
        log "  Restored /etc/cron.d/"
    fi

    # Per-user crontabs
    if [ -d "${TEMP_CRON_DIR}/crontabs/user_crontabs" ]; then
        mkdir -p /var/spool/cron/crontabs
        cp -r "${TEMP_CRON_DIR}/crontabs/user_crontabs/." /var/spool/cron/crontabs/
        chmod 600 /var/spool/cron/crontabs/* 2>/dev/null || true
        log "  Restored user crontabs"
    fi

    rm -rf "${TEMP_CRON_DIR}"
    log "Crontab restore complete."
else
    warn "No crontabs.tar.gz found in backup — skipping."
fi

# ── 7. Restart services ───────────────────────────────────────────────────────
log "Restarting Apache2 and MariaDB..."
systemctl restart apache2
systemctl restart mariadb

# ── 8. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Restore complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "  Apache2        : ${GREEN}running${NC}"
echo -e "  MariaDB        : ${GREEN}running${NC}  (root pass: ${YELLOW}${DB_PASS}${NC})"
echo -e "  Web root       : ${GREEN}${WEBROOT}${NC}"
echo -e "  Python scripts : ${GREEN}${PYTHON_SCRIPTS}${NC}  (venv: ${VENV_NAME})"
echo -e "  Crontabs       : ${GREEN}restored${NC}"
echo ""
