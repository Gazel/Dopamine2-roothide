#!/usr/bin/env bash
# install_lakasir.sh
# Lakasir one-shot installer for Ubuntu 22.04 (Azure B1s / 1 GB RAM)
# - Nginx + PHP 8.1 + MariaDB
# - 2G swapfile (prevents OOM during composer/migrations)
# - Clone repo, composer install, .env wiring
# - key:generate, tenant migrate + seed
# - Filament & Livewire assets
# - Nginx vhost, UFW firewall, Laravel scheduler cron

set -euo pipefail

# -------------------------
# Config (override via envs)
# -------------------------
DB_NAME="${DB_NAME:-lakasir}"
DB_USER="${DB_USER:-lakasir}"
DB_PASS="${DB_PASS:-ChangeMe123!}"     # <<< change or override at runtime
MY_DOMAIN="${MY_DOMAIN:-}"             # e.g., pos.example.com (leave empty to use server IP)
APP_DIR="${APP_DIR:-/var/www/lakasir}"
PHP_VERSION="${PHP_VERSION:-8.1}"      # keep 8.1 per project requirements
REPO_URL="${REPO_URL:-https://github.com/lakasir/lakasir.git}"

# -------------------------
# Sanity checks
# -------------------------
if ! grep -qi "ubuntu" /etc/os-release; then
  echo "This script targets Ubuntu. Aborting."; exit 1
fi

# -------------------------
# OS prep
# -------------------------
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl git unzip software-properties-common

# -------------------------
# Swap (2G)
# -------------------------
if ! sudo swapon --show | grep -q swapfile; then
  echo ">> Creating 2G swapfile..."
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo "/swapfile swap swap defaults 0 0" | sudo tee -a /etc/fstab >/dev/null
fi

# -------------------------
# Nginx
# -------------------------
sudo apt-get install -y nginx

# -------------------------
# PHP 8.1 + extensions
# -------------------------
if ! dpkg -l | grep -q "ondrej/php"; then
  sudo add-apt-repository ppa:ondrej/php -y
  sudo apt-get update -y
fi
sudo apt-get install -y \
  "php${PHP_VERSION}" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-common" \
  "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-bcmath"

# -------------------------
# Composer
# -------------------------
if ! command -v composer >/dev/null 2>&1; then
  EXPECTED_CHECKSUM="$(curl -s https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php -r "if (hash_file('sha384', 'composer-setup.php') !== '$EXPECTED_CHECKSUM') { echo 'Composer installer corrupt'; unlink('composer-setup.php'); exit(1); }"
  sudo php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f composer-setup.php
fi

# -------------------------
# MariaDB
# -------------------------
sudo apt-get install -y mariadb-server
sudo systemctl enable --now mariadb

echo ">> Creating database and user (if missing)..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# -------------------------
# App fetch
# -------------------------
sudo mkdir -p "$(dirname "$APP_DIR")"
if [ ! -d "$APP_DIR" ]; then
  sudo git clone "$REPO_URL" "$APP_DIR"
fi
sudo chown -R "$USER":"$USER" "$APP_DIR"
cd "$APP_DIR"

# -------------------------
# PHP dependencies
# -------------------------
composer install --no-dev --optimize-autoloader

# -------------------------
# .env wiring
# -------------------------
if [ ! -f .env ]; then
  cp .env.example .env
fi

APP_URL_LINE="APP_URL="
if [ -n "$MY_DOMAIN" ]; then
  APP_URL_LINE="APP_URL=https://${MY_DOMAIN}"
fi

php -r '
$env = file_get_contents(".env");
function set_kv($s,$k,$v){return preg_match("/^".$k."=/m",$s)?preg_replace("/^".$k."=.*/m",$k."=".$v,$s):($s.PHP_EOL.$k."=".$v.PHP_EOL);}
$env = set_kv($env,"'"${APP_URL_LINE%%=*}"'","'"${APP_URL_LINE#*=}"'");
$env = set_kv($env,"DB_CONNECTION","mysql");
$env = set_kv($env,"DB_HOST","127.0.0.1");
$env = set_kv($env,"DB_PORT","3306");
$env = set_kv($env,"DB_DATABASE","'"$DB_NAME"'");
$env = set_kv($env,"DB_USERNAME","'"$DB_USER"'");
$env = set_kv($env,"DB_PASSWORD","'"$DB_PASS"'");
file_put_contents(".env",$env);
'

# -------------------------
# Laravel bootstrap
# -------------------------
php artisan key:generate
php artisan storage:link || true

# Official guide: tenant migrations + seed
php artisan migrate --path=database/migrations/tenant --seed --force

# Filament & Livewire assets (no Node/JS build)
php artisan filament:assets
php artisan livewire:publish --assets

# -------------------------
# Permissions
# -------------------------
sudo chown -R www-data:www-data "$APP_DIR"
sudo find "$APP_DIR/storage" -type d -exec chmod 775 {} \;
sudo find "$APP_DIR/bootstrap/cache" -type d -exec chmod 775 {} \;

# -------------------------
# Nginx vhost
# -------------------------
SERVER_NAME_VALUE="_"
[ -n "$MY_DOMAIN" ] && SERVER_NAME_VALUE="$MY_DOMAIN"

sudo bash -c "cat >/etc/nginx/sites-available/lakasir.conf" <<NGX
server {
    listen 80;
    server_name ${SERVER_NAME_VALUE};

    root ${APP_DIR}/public;
    index index.php index.html;

    client_max_body_size 20m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_read_timeout 180s;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 7d;
        access_log off;
    }
}
NGX

sudo ln -sf /etc/nginx/sites-available/lakasir.conf /etc/nginx/sites-enabled/lakasir.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx "php${PHP_VERSION}-fpm"

# -------------------------
# Firewall (UFW)
# -------------------------
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow OpenSSH || true
  sudo ufw allow 'Nginx Full' || true
  yes | sudo ufw enable || true
fi

# -------------------------
# Laravel scheduler (cron as www-data)
# -------------------------
( crontab -u www-data -l 2>/dev/null | grep -v 'schedule:run' ; echo "* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1" ) | sudo crontab -u www-data -

echo "====================================================="
echo " Lakasir install complete."
echo " URL: http://${MY_DOMAIN:-<YOUR_SERVER_IP>}"
echo " DB:  ${DB_NAME} (user ${DB_USER})"
echo " Path: ${APP_DIR}"
echo " Tip: Add HTTPS with certbot after DNS is ready."
echo "====================================================="
