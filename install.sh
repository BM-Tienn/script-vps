#!/bin/bash
set -e

echo "🚀 Bắt đầu cài đặt N8N (PM2 + PostgreSQL + Caddy SSL)..."

# Kiểm tra quyền sudo
if [ "$(id -u)" != "0" ] && ! sudo -v >/dev/null 2>&1; then
  echo "❌ Script này cần quyền sudo để cài đặt. Vui lòng chạy với người dùng có quyền sudo."
  exit 1
fi

# Hàm hỏi input với giá trị mặc định
input_with_default() {
  local prompt="$1"
  local default="$2"
  local result
  read -p "$prompt [$default]: " result
  echo "${result:-$default}"
}

# ======== Nhập thông tin cấu hình ========
DOMAIN=$(input_with_default "Nhập domain/subdomain cho N8N" "n8n.example.com")
EMAIL=$(input_with_default "Nhập email để cài SSL (Let's Encrypt)" "admin@example.com")
N8N_BASIC_AUTH_USER=$(input_with_default "Nhập username đăng nhập N8N" "admin")

# Nhập mật khẩu đăng nhập n8n
while true; do
  read -s -p "Nhập password đăng nhập N8N: " pass1
  echo
  read -s -p "Nhập lại password: " pass2
  echo
  if [ "$pass1" = "$pass2" ] && [ -n "$pass1" ]; then
    N8N_BASIC_AUTH_PASSWORD="$pass1"
    break
  else
    echo "❌ Mật khẩu không khớp hoặc rỗng. Vui lòng nhập lại."
  fi
done

# ======== Cấu hình PostgreSQL ========
POSTGRES_DB="n8n"
POSTGRES_USER="n8n_user"
POSTGRES_PASSWORD=$(openssl rand -base64 16)

# ======== Xử lý file .env ========
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
  echo "⚠️  File .env đã tồn tại."
  cp "$ENV_FILE" "$ENV_FILE.bak"
  echo "✅ Đã tạo bản sao lưu: $ENV_FILE.bak"
fi

# Sinh encryption key nếu chưa có
N8N_ENCRYPTION_KEY=$(grep "^N8N_ENCRYPTION_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
fi

# Ghi đè file .env
cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL

POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY

N8N_HOST=0.0.0.0
N8N_PORT=5678
EOF

chmod 600 "$ENV_FILE"
echo "✅ Đã tạo file .env an toàn."

# ======== Cài đặt các phần mềm cần thiết ========
echo "�� Cập nhật và cài đặt phần mềm cần thiết..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl gnupg postgresql build-essential caddy unzip

# Kiểm tra PostgreSQL đã chạy chưa
echo "🔄 Kiểm tra và khởi động PostgreSQL..."
if ! systemctl is-active --quiet postgresql; then
  sudo systemctl start postgresql
  sudo systemctl enable postgresql
fi

# Kiểm tra nếu port 5678 đã được sử dụng
if netstat -tuln | grep -q ":5678"; then
  echo "⚠️ Port 5678 đã được sử dụng. N8N sẽ không thể khởi động."
  echo "Vui lòng tắt ứng dụng đang sử dụng port 5678 trước khi tiếp tục."
  exit 1
fi

# Cài Node.js & PM2
echo "📦 Cài đặt Node.js và PM2..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# Cài đặt n8n
echo "📦 Cài đặt N8N..."
sudo npm install -g n8n

# ======== Cấu hình PostgreSQL ========
echo "🛢️ Cấu hình cơ sở dữ liệu PostgreSQL..."
DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB'" 2>/dev/null || echo "0")
if [ "$DB_EXISTS" != "1" ]; then
  sudo -u postgres createdb "$POSTGRES_DB"
fi

USER_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_USER'" 2>/dev/null || echo "0")
if [ "$USER_EXISTS" != "1" ]; then
  sudo -u postgres psql -c "CREATE ROLE $POSTGRES_USER LOGIN PASSWORD '$POSTGRES_PASSWORD';"
fi

sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;"

# ======== Chuẩn bị thư mục chạy N8N ========
echo "📁 Chuẩn bị thư mục cho N8N..."
sudo mkdir -p /opt/n8n
sudo cp "$ENV_FILE" /opt/n8n/.env
sudo chown -R $USER:$USER /opt/n8n
chmod 600 /opt/n8n/.env

# Kiểm tra quyền
if [ ! -w "/opt/n8n" ]; then
  echo "❌ Không có quyền ghi vào thư mục /opt/n8n. Đang sửa quyền..."
  sudo chown -R $USER:$USER /opt/n8n
  chmod -R 755 /opt/n8n
fi

# ======== Cấu hình PM2 ========
echo "⚙️ Cấu hình PM2..."
cat > /opt/n8n/ecosystem.config.js <<EOL
module.exports = {
  apps: [{
    name: "n8n",
    script: "$(which n8n)",
    exec_mode: "fork",
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: "1G",
    log_date_format: "YYYY-MM-DD HH:mm:ss",
    env: {
      NODE_ENV: "production",
      DOMAIN: "${DOMAIN}",
      VUE_APP_URL_BASE_API: "https://${DOMAIN}",
      N8N_HOST: "0.0.0.0",
      N8N_PORT: 5678,
      N8N_PROTOCOL: "https",
      N8N_PATH: "/",
      N8N_BASIC_AUTH_ACTIVE: true,
      N8N_BASIC_AUTH_USER: "${N8N_BASIC_AUTH_USER}",
      N8N_BASIC_AUTH_PASSWORD: "${N8N_BASIC_AUTH_PASSWORD}",
      N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}",
      DB_TYPE: "postgresdb",
      DB_POSTGRESDB_HOST: "localhost",
      DB_POSTGRESDB_PORT: 5432,
      DB_POSTGRESDB_DATABASE: "${POSTGRES_DB}",
      DB_POSTGRESDB_USER: "${POSTGRES_USER}",
      DB_POSTGRESDB_PASSWORD: "${POSTGRES_PASSWORD}",
      GENERIC_TIMEZONE: "Asia/Ho_Chi_Minh"
    }
  }]
}
EOL

# ======== Khởi chạy N8N bằng PM2 ========
echo "🚀 Khởi động N8N với PM2..."
cd /opt/n8n
pm2 delete n8n 2>/dev/null || true  # Xóa instance cũ nếu có
pm2 start ecosystem.config.js
pm2_status=$?

if [ $pm2_status -ne 0 ]; then
  echo "❌ Không thể khởi động N8N với PM2. Kiểm tra lại cấu hình."
  exit 1
fi

pm2 save
pm2_startup=$(pm2 startup systemd -u $USER --hp $HOME | tail -n 1)
sudo bash -c "$pm2_startup"

# Kiểm tra N8N đã chạy chưa
echo "🔄 Kiểm tra N8N đã chạy chưa..."
sleep 5
if ! curl -s http://localhost:5678 >/dev/null; then
  echo "⚠️ N8N chưa chạy. Kiểm tra logs để biết thêm thông tin:"
  pm2 logs n8n --lines 20
else
  echo "✅ N8N đã chạy thành công!"
fi

# ======== Cấu hình Caddy để reverse proxy ========
echo "🔒 Cấu hình Caddy và SSL..."
cat > Caddyfile.template <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy localhost:5678
    tls ${EMAIL}
}
EOF

envsubst < Caddyfile.template | sudo tee /etc/caddy/Caddyfile > /dev/null
sudo systemctl reload caddy
caddy_status=$?

if [ $caddy_status -ne 0 ]; then
  echo "⚠️ Không thể khởi động lại Caddy. SSL có thể không hoạt động."
else
  echo "✅ Caddy đã được cấu hình thành công!"
fi

# ======== Kết thúc ========
echo "✅ Cài đặt hoàn tất!"
echo "🌐 Truy cập: https://${DOMAIN}"
echo "👤 Tài khoản: ${N8N_BASIC_AUTH_USER}"
echo ""
echo "📋 Thông tin chi tiết:"
echo "- N8N đang chạy trên cổng 5678"
echo "- PostgreSQL database: ${POSTGRES_DB}"
echo "- PM2 đã được cấu hình để tự khởi động khi hệ thống khởi động"
echo "- Caddy đã cấu hình SSL tự động cho domain ${DOMAIN}"
echo ""
echo "💡 Kiểm tra trạng thái: pm2 status"
echo "💡 Xem logs: pm2 logs n8n"
