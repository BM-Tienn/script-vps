# 🚀 N8N Self-hosted Installer

Script tự động cài đặt N8N (PM2 + PostgreSQL) và cấp SSL tự động qua Caddy.

## 🛠 Cài đặt

```bash
git clone https://github.com/yourname/n8n-selfhost-installer.git
cd n8n-selfhost-installer
cp .env.example .env
# chỉnh sửa .env cho đúng domain, email và DB info
chmod +x install.sh
./install.sh
