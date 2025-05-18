echo "💡 Nhập domain cho n8n (ví dụ: n8n.example.com):"
read -rp "👉 Domain: " DOMAIN

# Kiểm tra domain rỗng
if [[ -z "$DOMAIN" ]]; then
  echo "❌ Domain không được để trống!"
  exit 1
fi

# Cấu hình mặc định
N8N_USER="n8n"
N8N_PORT=5678
N8N_DIR="/home/$N8N_USER/n8n"
CADDY_FILE="/etc/caddy/Caddyfile"

echo "🚀 Cài đặt n8n cho domain: $DOMAIN"

# Cập nhật hệ thống
sudo apt update && sudo apt upgrade -y

# Cài Node.js nếu chưa có
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt install -y nodejs
fi

# Cài pm2
sudo npm install -g pm2

# Tạo user riêng cho n8n nếu chưa tồn tại
if ! id "$N8N_USER" &>/dev/null; then
  sudo adduser --disabled-password --gecos "" $N8N_USER
  sudo usermod -aG sudo $N8N_USER
fi

# Cài đặt n8n (chạy dưới user riêng)
sudo -u $N8N_USER bash <<EOF
mkdir -p $N8N_DIR
cd $N8N_DIR
npm init -y
npm install n8n
pm2 start ./node_modules/.bin/n8n --name n8n -- start
pm2 save
EOF

# Cài đặt Caddy (nếu chưa có)
if ! command -v caddy >/dev/null; then
  sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt update
  sudo apt install caddy -y
fi

# Ghi Caddyfile
sudo tee $CADDY_FILE >/dev/null <<EOL
$DOMAIN {
    reverse_proxy localhost:$N8N_PORT
}
EOL

# Khởi động Caddy
sudo systemctl reload caddy
sudo systemctl enable caddy
sudo systemctl restart caddy

echo "✅ Cài đặt hoàn tất. Truy cập: https://$DOMAIN"
