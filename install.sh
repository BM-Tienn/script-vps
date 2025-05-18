#!/bin/bash
set -e

echo "🚀 Bắt đầu cài đặt N8N (PM2 + PostgreSQL + Caddy SSL)..."

# Hàm hỏi input có giá trị mặc định
input_with_default() {
  local prompt="$1"
  local default="$2"
  local result
  read -p "$prompt [$default]: " result
  echo "${result:-$default}"
}

# Nhập các giá trị bắt buộc
DOMAIN=$(input_with_default "Nhập domain (subdomain) cho N8N" "n8n.example.com")
EMAIL=$(input_with_default "Nhập email để cài SSL (Let's Encrypt)" "your@email.com")
N8N_BASIC_AUTH_USER=$(input_with_default "Nhập username đăng nhập n8n" "admin")

while true; do
  read -s -p "Nhập password đăng nhập n8n: " pass1
  echo
  read -s -p "Nhập lại password: " pass2
  echo
  if [ "$pass1" = "$pass2" ] && [ -n "$pass1" ]; then
    N8N_BASIC_AUTH_PASSWORD="$pass1"
    break
  else
    echo "❌ Mật khẩu không khớp hoặc rỗng, vui lòng nhập lại."
  fi
done

POSTGRES_DB="n8n"
POSTGRES_USER="n8n_user"

# Tạo hoặc đọc file .env
ENV_FILE=".env"
if [ -f "$ENV_FILE" ]; then
  echo "⚠️  Đã tồn tại file .env, sẽ cập nhật lại các biến cần thiết..."
else
  echo "Tạo file .env mới..."
  touch "$ENV_FILE"
fi

# Sinh key mã hóa nếu chưa có
if grep -q "^N8N_ENCRYPTION_KEY=" "$ENV_FILE"; then
  N8N_ENCRYPTION_KEY=$(grep "^N8N_ENCRYPTION_KEY=" "$ENV_FILE" | cut -d= -f2-)
else
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
fi

# Viết vào file .env (ghi đè các biến quan trọng)
cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL

POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=supersecurepassword

N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY

N8N_HOST=0.0.0.0
N8N_PORT=5678
EOF

echo "✅ Đã tạo/cập nhật file .env với cấu hình bạn nhập."

# Cài đặt dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl gnupg postgresql build-essential caddy unzip

# Cài Node.js 18.x & PM2
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# Cài N8N global
sudo npm install -g n8n

# Setup PostgreSQL
sudo -u postgres psql <<EOF
CREATE DATABASE IF NOT EXISTS $POSTGRES_DB;
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$POSTGRES_USER') THEN
      CREATE ROLE $POSTGRES_USER LOGIN PASSWORD 'supersecurepassword';
   END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;
EOF

# Tạo thư mục n8n và sao chép .env
sudo mkdir -p /opt/n8n
sudo cp "$ENV_FILE" /opt/n8n/.env
sudo chown -R $USER:$USER /opt/n8n

# Tạo file ecosystem.config.js cho PM2
cat > /opt/n8n/ecosystem.config.js <<EOL
module.exports = {
  apps: [{
    name: "n8n",
    script: "n8n",
    env: {
      N8N_PORT: 5678,
      N8N_HOST: "0.0.0.0",
      VUE_APP_URL_BASE_API: "https://${DOMAIN}",
      DOMAIN: "${DOMAIN}",
      N8N_BASIC_AUTH_USER: "${N8N_BASIC_AUTH_USER}",
      N8N_BASIC_AUTH_PASSWORD: "${N8N_BASIC_AUTH_PASSWORD}",
      N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}",
      DB_TYPE: "postgresdb",
      DB_POSTGRESDB_HOST: "localhost",
      DB_POSTGRESDB_PORT: 5432,
      DB_POSTGRESDB_DATABASE: "${POSTGRES_DB}",
      DB_POSTGRESDB_USER: "${POSTGRES_USER}",
      DB_POSTGRESDB_PASSWORD: "supersecurepassword",
      GENERIC_TIMEZONE: "Asia/Ho_Chi_Minh"
    }
  }]
}
EOL

# Khởi chạy với PM2
cd /opt/n8n
pm2 start ecosystem.config.js
pm2 save
pm2 startup systemd -u $USER --hp $HOME

# Tạo Caddyfile template
cat > Caddyfile.template <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy localhost:5678
    tls $EMAIL
}
EOF

# Cấu hình Caddy với domain và reload
envsubst < Caddyfile.template | sudo tee /etc/caddy/Caddyfile > /dev/null
sudo systemctl reload caddy

echo "✅ Hoàn tất! Truy cập https://${DOMAIN} với username: ${N8N_BASIC_AUTH_USER}"
