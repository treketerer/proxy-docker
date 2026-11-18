
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash certbot.sh"
    exit 1
fi

# Load environment
set -a
source "$ROOT/.env"
set +a

: "${DOMAIN:?DOMAIN is missing}"
: "${PUBLIC_IP:?PUBLIC_IP is missing}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is missing}"

# Standard Let's Encrypt directories
mkdir -p \
    "$ROOT/config/nginx" \
    "$ROOT/config/telemt" \
    "$ROOT/certbot/www" \
    /etc/letsencrypt \
    /var/lib/letsencrypt \
    /var/log/letsencrypt

CONF="$ROOT/config/nginx/default.conf"

# Render only our environment placeholders.
# NGINX variables such as $host and $uri remain untouched.
render() {
    local src="$1"
    local dst="$2"
    local content

    content="$(<"$src")"
    content="${content//\$\{DOMAIN\}/$DOMAIN}"
    content="${content//\$\{PUBLIC_IP\}/$PUBLIC_IP}"

    printf '%s\n' "$content" > "$dst"
}

# Check templates
for file in \
    config/nginx/default.conf.ssl.template \
    config/telemt/telemt.toml.template
do
    if [[ ! -f "$file" ]]; then
        echo "Missing template: $file" >&2
        exit 1
    fi
done

# Generate Telemt config
render \
    config/telemt/telemt.toml.template \
    config/telemt/telemt.toml

# Temporary HTTP config for ACME challenge
cat > "$CONF" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
NGINX

echo "[1/4] Starting NGINX..."

docker compose up -d nginx

docker compose exec -T nginx nginx -t
docker compose exec -T nginx nginx -s reload

# Obtain certificate
echo "[2/4] Requesting Let's Encrypt certificate..."

docker run --rm \
    --name certbot \
    -v "$ROOT/certbot/www:/var/www/certbot" \
    -v /etc/letsencrypt:/etc/letsencrypt \
    -v /var/lib/letsencrypt:/var/lib/letsencrypt \
    -v /var/log/letsencrypt:/var/log/letsencrypt \
    certbot/certbot:latest certonly \
    --webroot \
    -w /var/www/certbot \
    -d "$DOMAIN" \
    --cert-name "$DOMAIN" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --keep-until-expiring \
    --non-interactive

# Verify certificate
CERT="/etc/letsencrypt/live/$DOMAIN"

if [[ ! -s "$CERT/fullchain.pem" || ! -s "$CERT/privkey.pem" ]]; then
    echo "Certificate files not found!" >&2
    exit 1
fi

# Generate production NGINX config
echo "[3/4] Generating HTTPS configuration..."

render \
    config/nginx/default.conf.ssl.template \
    "$CONF"

# Validate and reload
echo "[4/4] Reloading NGINX..."

docker compose exec -T nginx nginx -t
docker compose exec -T nginx nginx -s reload

echo
echo "Certificate ready: $CERT/"
echo "NGINX HTTPS configuration applied."
