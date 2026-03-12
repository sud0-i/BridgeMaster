#!/bin/bash

if [ "$1" == "--cron-backup" ]; then
    tg_backup
    exit 0
fi

if [ "$EUID" -ne 0 ]; then echo "❌ Запусти скрипт от root"; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -yq sshpass curl jq openssl socat nginx certbot python3-certbot-nginx dnsutils ufw gnupg qrencode tar docker.io docker-compose netcat-openbsd bc >/dev/null 2>&1
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa >/dev/null 2>&1

show_system_status() {
    local CPU=$(top -bn1 | grep load | awk '{printf "%.2f", $(NF-2)}')
    local RAM=$(free -m | awk 'NR==2{printf "%s/%sMB (%.2f%%)", $3,$2,$3*100/$2 }')
    local XRAY_STAT=$(systemctl is-active xray 2>/dev/null)
    local NGINX_STAT=$(systemctl is-active nginx 2>/dev/null)
    
    [[ "$XRAY_STAT" == "active" ]] && XRAY_STAT="🟢 Активен" || XRAY_STAT="🔴 Отключен"
    [[ "$NGINX_STAT" == "active" ]] && NGINX_STAT="🟢 Активен" || NGINX_STAT="🔴 Отключен"

    echo "📊 Сервер: CPU: $CPU | RAM: $RAM"
    echo "⚙️ Службы: Xray: $XRAY_STAT | Nginx: $NGINX_STAT"
    
    if [ -f /usr/local/etc/xray/config.json ]; then
        echo "🌍 Статус EU-нод в мосте:"
        local IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u)
        if [ -z "$IPS" ]; then
            echo "   Нет подключенных удаленных серверов."
        else
            for IP in $IPS; do
                if nc -z -w 2 "$IP" 443 2>/dev/null; then
                    echo "   🟢 $IP - Online"
                else
                    echo "   🔴 $IP - Offline (порт 443 недоступен)"
                fi
            done
        fi
    fi
    if [ -f /var/lib/xray/cert/fullchain.pem ]; then
        local EXP_DATE=$(openssl x509 -enddate -noout -in /var/lib/xray/cert/fullchain.pem 2>/dev/null | cut -d= -f2)
        if [ -n "$EXP_DATE" ]; then
            local EXP_SEC=$(date -d "$EXP_DATE" +%s 2>/dev/null)
            local NOW_SEC=$(date +%s)
            local DAYS_LEFT=$(( (EXP_SEC - NOW_SEC) / 86400 ))
            if [ "$DAYS_LEFT" -le 7 ]; then
                echo "🔐 SSL Сертификат: 🔴 Осталось $DAYS_LEFT дней (скоро обновится)"
            else
                echo "🔐 SSL Сертификат: 🟢 Осталось $DAYS_LEFT дней"
            fi
        fi
    fi
    echo "---------------------------------------------------------"
}

verify_dns_propagation() {
    local DOM_TO_CHECK=$1
    local REAL_IP=$(curl -s4 ifconfig.me)
    echo -e "\n🌍 Проверка DNS: привязка $DOM_TO_CHECK к $REAL_IP..."
    
    while true; do
        local RESOLVED_IP=$(dig +short "$DOM_TO_CHECK" | tail -n1)
        
        if [ "$RESOLVED_IP" == "$REAL_IP" ]; then
            echo "✅ Отлично! DNS-записи обновлены, домен указывает на этот сервер."
            return 0
        fi
        
        echo "⚠️ ВНИМАНИЕ: Домен $DOM_TO_CHECK сейчас указывает на IP: ${RESOLVED_IP:-"Нет записи (пусто)"}"
        echo "👉 Зайди в панель регистратора домена и измени A-запись на: $REAL_IP"
        echo "---------------------------------------------------------"
        echo "1) 🔄 Проверить DNS еще раз (нажми после смены записи)"
        echo "2) ⏭️ Пропустить проверку (Например, если домен за Cloudflare Proxy)"
        read -p "Твой выбор (1-2): " DNS_CHOICE
        
        if [ "$DNS_CHOICE" == "2" ]; then
            echo "⚠️ Проверка DNS пропущена принудительно. Убедись, что клиенты смогут подключиться!"
            return 0
        fi
    done
}

manage_users() {
    if [ ! -f /usr/local/etc/xray/config.json ]; then echo "❌ Xray конфиг не найден!"; return; fi
    
    gen_html() {
        local U=$1; local ID=$2; local URL="https://$3/sub/$2"
        cat <<EOF > /var/www/html/sub/$ID.html
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>VPN: $U</title><style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px;text-align:center}.card{background:#1e1e1e;padding:30px;border-radius:16px;max-width:400px;width:100%}.btn{display:block;width:100%;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold;font-size:16px;box-sizing:border-box}.btn-ios{background:#007AFF;color:#fff}.btn-android{background:#3DDC84;color:#000}.btn-win{background:#00A4EF;color:#fff}.raw-link{background:#111;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;color:#666;word-break:break-all;margin-top:10px;user-select:all}.apps{background:#2a2a2a;padding:15px;border-radius:12px;margin-bottom:20px;text-align:left;font-size:14px}.apps a{color:#4da6ff;text-decoration:none;display:block;margin-bottom:8px}.apps a:hover{text-decoration:underline}</style></head><body><div class="card"><h1>🔑 Привет, $U!</h1>
<div class="apps"><b>Шаг 1. Установи приложение:</b><br><br><a href="https://apps.apple.com/us/app/v2raytun/id6476628951">🍏 iOS: V2rayTun</a><a href="https://play.google.com/store/apps/details?id=com.v2raytun.android">🤖 Android: V2rayTun</a><a href="https://github.com/hiddify/hiddify-next/releases">💻 PC/Mac: Hiddify Next</a></div>
<p><b>Шаг 2. Нажми для настройки:</b></p>
<a href="v2raytun://import/$URL" class="btn btn-win">🚀 Подключить V2rayTun</a><a href="hiddify://install-config?url=$URL" class="btn btn-android">🤖 Подключить Hiddify</a><a href="v2box://install-sub?url=$URL" class="btn btn-ios">🍏 Подключить V2Box</a>
<p style="font-size:12px;margin-top:20px;">Ручная настройка (скопируй ссылку):</p><div class="raw-link" onclick="navigator.clipboard.writeText(this.innerText); alert('Скопировано!');">$URL</div></div></body></html>
EOF
    }

    while true; do
        echo -e "\n👥 МЕНЕДЖЕР ПОЛЬЗОВАТЕЛЕЙ (RU-МОСТ)"
        echo "1) 📋 Список пользователей"
        echo "2) ➕ Добавить пользователя"
        echo "3) ➖ Удалить пользователя"
        echo "4) 📱 Показать ссылки пользователя (HTML + VLESS + QR)"
        echo "5) 🚑 Сгенерировать резервные прямые ссылки (на EU-ноды)"
        echo "0) ↩️ Вернуться"
        read -p "Выбор: " U_A
        
        case $U_A in
            1)
                echo -e "\nАктивные пользователи:"
                jq -r '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | "👤 \(.email // "Без имени") (UUID: \(.id))"' /usr/local/etc/xray/config.json
                ;;
            2)
                read -p "Введи имя (английскими без пробелов): " U_NAME
                [ -z "$U_NAME" ] && continue
                NEW_UUID=$(xray uuid)
                
                jq --arg id "$NEW_UUID" --arg email "$U_NAME" '(.inbounds[]? | select(.tag=="client-in") | .settings.clients) += [{"id": $id, "flow": "xtls-rprx-vision", "email": $email}]' /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
                if xray run -test -config /tmp/xray_tmp.json >/dev/null 2>&1; then
                    mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json; systemctl restart xray
                    echo "✅ Пользователь $U_NAME добавлен!"
                    
                    DOMAIN=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v "^README$" | head -n 1)
                    [ -z "$DOMAIN" ] && DOMAIN=$(curl -s4 ifconfig.me)
                    L_NEW="vless://$NEW_UUID@$DOMAIN:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$DOMAIN#$U_NAME"
                    
                    mkdir -p /var/www/html/sub
                    echo -n "$L_NEW" | base64 -w 0 > /var/www/html/sub/$NEW_UUID
                    gen_html "$U_NAME" "$NEW_UUID" "$DOMAIN"
                    
                    echo -e "\n🌍 СТРАНИЦА НАСТРОЙКИ (Дай эту ссылку пользователю):"
                    echo "https://$DOMAIN/sub/${NEW_UUID}.html"
                    
                    echo -e "\n🔑 ПРЯМОЙ КЛЮЧ VLESS:"
                    echo "$L_NEW"
                    qrencode -t UTF8 "$L_NEW"
                else
                    echo "❌ Ошибка конфига!"; rm -f /tmp/xray_tmp.json
                fi
                ;;
            3)
                read -p "Введи точное Имя или UUID для удаления: " U_DEL
                [ -z "$U_DEL" ] && continue
                
                T_UUID=$(jq -r --arg u "$U_DEL" '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | select(.id == $u or .email == $u) | .id' /usr/local/etc/xray/config.json | head -n 1)
                jq --arg del "$U_DEL" '(.inbounds[]? | select(.tag=="client-in") | .settings.clients) |= map(select(.id != $del and .email != $del))' /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
                if xray run -test -config /tmp/xray_tmp.json >/dev/null 2>&1; then
                    mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json; systemctl restart xray
                    [ -n "$T_UUID" ] && rm -f /var/www/html/sub/$T_UUID /var/www/html/sub/${T_UUID}.html
                    echo "✅ Пользователь $U_DEL удален!"
                else
                    echo "❌ Ошибка конфига!"; rm -f /tmp/xray_tmp.json
                fi
                ;;
            4)
                read -p "Введи имя или UUID пользователя: " U_SHOW
                [ -z "$U_SHOW" ] && continue
                DOMAIN=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v "^README$" | head -n 1)
                [ -z "$DOMAIN" ] && DOMAIN=$(curl -s4 ifconfig.me)
                
                T_UUID=$(jq -r --arg u "$U_SHOW" '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | select(.id == $u or .email == $u) | .id' /usr/local/etc/xray/config.json | head -n 1)
                T_MAIL=$(jq -r --arg u "$U_SHOW" '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | select(.id == $u or .email == $u) | .email' /usr/local/etc/xray/config.json | head -n 1)
                
                if [ -n "$T_UUID" ]; then
                    local L_USR="vless://$T_UUID@$DOMAIN:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$DOMAIN#$T_MAIL"
                    mkdir -p /var/www/html/sub
                    echo -n "$L_USR" | base64 -w 0 > /var/www/html/sub/$T_UUID
                    gen_html "$T_MAIL" "$T_UUID" "$DOMAIN"
                    
                    echo -e "\n🌍 СТРАНИЦА НАСТРОЙКИ (Для $T_MAIL):"
                    echo "https://$DOMAIN/sub/${T_UUID}.html"
                    
                    echo -e "\n🔑 ПРЯМОЙ КЛЮЧ VLESS:"
                    echo "$L_USR"
                    qrencode -t UTF8 "$L_USR"
                else
                    echo "❌ Пользователь не найден."
                fi
                ;;
            5)
                echo -e "\n🛡️ РЕЗЕРВНЫЕ ПРЯМЫЕ ССЫЛКИ НА EU-НОДЫ:"
                jq -c '.outbounds[]? | select(.protocol=="vless" and .streamSettings.security=="reality")' /usr/local/etc/xray/config.json 2>/dev/null | while read -r row; do
                    TAG=$(echo "$row" | jq -r '.tag')
                    NET=$(echo "$row" | jq -r '.streamSettings.network')
                    IP=$(echo "$row" | jq -r '.settings.vnext[0].address')
                    PORT=$(echo "$row" | jq -r '.settings.vnext[0].port')
                    U=$(echo "$row" | jq -r '.settings.vnext[0].users[0].id')
                    SNI=$(echo "$row" | jq -r '.streamSettings.realitySettings.serverName')
                    PUB=$(echo "$row" | jq -r '.streamSettings.realitySettings.publicKey')
                    SID=$(echo "$row" | jq -r '.streamSettings.realitySettings.shortId')
                    
                    if [ "$NET" == "xhttp" ]; then
                        XP=$(echo "$row" | jq -r '.streamSettings.xhttpSettings.path')
                        echo -e "\n🌍 $TAG (xHTTP, Порт $PORT):"
                        echo "vless://$U@$IP:$PORT?security=reality&encryption=none&pbk=$PUB&headerType=none&fp=chrome&type=xhttp&sni=$SNI&sid=$SID&path=$XP#$TAG"
                    else
                        echo -e "\n🌍 $TAG (TCP, Порт $PORT):"
                        echo "vless://$U@$IP:$PORT?security=reality&encryption=none&pbk=$PUB&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SID#$TAG"
                    fi
                done
                ;;
            0) return ;;
            *) echo "❌ Неверный выбор" ;;
        esac
    done
}

setup_ssh_notify() {
    echo -e "\n🔔 НАСТРОЙКА УВЕДОМЛЕНИЙ ОБ SSH-ВХОДАХ"
    if [ ! -f ~/.vpn_tg.conf ]; then
        echo "⚠️ Сначала настройте Telegram бота (пункт Бекап), чтобы задать Токен и Chat ID."
        read -p "Нажми Enter..." DUMMY
        return
    fi
    source ~/.vpn_tg.conf

    cat <<EOF > /etc/profile.d/tg_ssh_notify.sh
#!/bin/bash
if [ -n "\$SSH_CLIENT" ]; then
    IP=\$(echo "\$SSH_CLIENT" | awk '{print \$1}')
    HOSTNAME=\$(hostname)
    MSG="🚨 *ВНИМАНИЕ! Вход по SSH*%0A%0A🖥 *Сервер:* \$HOSTNAME%0A👤 *Пользователь:* \$USER%0A🌐 *IP адрес:* \$IP%0A⏰ *Время:* \$(date '+%Y-%m-%d %H:%M:%S')"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="\$MSG" -d parse_mode="Markdown" >/dev/null 2>&1 &
fi
EOF
    chmod +x /etc/profile.d/tg_ssh_notify.sh
    echo "✅ Уведомления включены! Теперь при каждом входе бот будет присылать алерт."
    read -p "Нажми Enter..." DUMMY
}

harden_system() {
    echo "🛡️ УСИЛЕНИЕ БЕЗОПАСНОСТИ"
    echo "1) 💾 Создать SWAP (2GB)"
    echo "2) 🚪 Изменить порт SSH"
    echo "3) 🚔 Установить Fail2Ban"
    read -p "Выбор: " H_C
    if [ "$H_C" == "1" ]; then
        if free | awk '/^Swap:/ {exit !$2}'; then echo "✅ SWAP уже есть!"; else
            fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
            echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo "✅ SWAP создан!"; fi
    elif [ "$H_C" == "2" ]; then
        read -p "Новый порт (1024-65535): " NP
        if [[ "$NP" =~ ^[0-9]+$ ]] && [ "$NP" -ge 1024 ]; then
            ufw allow $NP/tcp; ufw limit $NP/tcp; sed -i "s/^#*Port .*/Port $NP/" /etc/ssh/sshd_config
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            echo "✅ Порт SSH изменен на $NP."
        else echo "❌ Неверный порт."; fi
    elif [ "$H_C" == "3" ]; then
        apt-get install -yq fail2ban; 
        echo -e "[sshd]\nenabled=true\nport=1:65535\nmaxretry=5\nbantime=24h" > /etc/fail2ban/jail.local
        systemctl restart fail2ban; systemctl enable fail2ban
        echo "✅ Fail2Ban установлен."
    fi
}

setup_tg_bot() {
    echo -e "\n🤖 МЕНЕДЖЕР TELEGRAM БОТА (GOLANG + PRO EDITION)"
    echo "1) 🚀 Установить / Обновить"
    echo "2) 🛑 Удалить бота"
    echo "0) ↩️ Назад"
    read -p "Выбор: " B_ACT

    if [ "$B_ACT" == "2" ]; then
        systemctl disable --now vpn-tg-bot 2>/dev/null
        rm -f /etc/systemd/system/vpn-tg-bot.service /usr/local/bin/vpn-bot
        systemctl daemon-reload
        echo "✅ Бот удален."
        return
    elif [ "$B_ACT" == "0" ]; then return; fi

    if [ ! -f ~/.vpn_tg.conf ]; then
        echo "⚠️ Сначала настройте Telegram (Пункт: Бекап)."; sleep 2; return
    fi

    echo "⏳ 1/4 Подготовка окружения Go..."
    cd / && cd /tmp || exit
    
    wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    
    mkdir -p /usr/src/vpn-bot
    cd /usr/src/vpn-bot
    go mod init vpn-bot >/dev/null 2>&1
    go get -u github.com/go-telegram-bot-api/telegram-bot-api/v5 >/dev/null 2>&1

    echo "⏳ 2/4 Генерация исходного кода (Go)..."
cat << 'GO_EOF' > main.go
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

const htmlTemplate = `<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>VPN: %s</title><style>body{background-color:#121212;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px;text-align:center}.card{background-color:#1e1e1e;padding:30px;border-radius:16px;box-shadow:0 4px 20px rgba(0,0,0,0.5);max-width:400px;width:100%%}h1{font-size:22px;margin-bottom:10px;color:#ffffff}.btn{display:block;width:100%%;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold;font-size:16px;box-sizing:border-box;transition:transform 0.1s}.btn:active{transform:scale(0.98)}.btn-ios{background-color:#007AFF;color:white}.btn-android{background-color:#3DDC84;color:#000}.btn-win{background-color:#00A4EF;color:white}.raw-link{background:#111;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;color:#666;word-break:break-all;margin-top:10px;user-select:all;cursor:pointer}.apps{background:#2a2a2a;padding:15px;border-radius:12px;margin-bottom:20px;text-align:left;font-size:14px}.apps a{color:#4da6ff;text-decoration:none;display:block;margin-bottom:8px}.apps a:hover{text-decoration:underline}.footer{margin-top:30px;font-size:12px;color:#555}</style></head><body><div class="card"><h1>🔑 Привет, %s!</h1><div class="apps"><b>Шаг 1. Установи приложение:</b><br><br><a href="https://apps.apple.com/us/app/v2raytun/id6476628951">🍏 iOS: V2rayTun</a><a href="https://play.google.com/store/apps/details?id=com.v2raytun.android">🤖 Android: V2rayTun</a><a href="https://github.com/hiddify/hiddify-next/releases">💻 PC/Mac: Hiddify Next</a></div><p><b>Шаг 2. Нажми для настройки:</b></p><a href="v2raytun://import/%s" class="btn btn-win">🚀 Подключить V2rayTun</a><a href="hiddify://install-config?url=%s" class="btn btn-android">🤖 Подключить Hiddify</a><a href="v2box://install-sub?url=%s" class="btn btn-ios">🍏 Подключить V2Box</a><p style="font-size:12px;margin-top:20px;">Ручная настройка (скопируй ссылку):</p><div class="raw-link" onclick="navigator.clipboard.writeText(this.innerText); alert('Скопировано!');">%s</div></div><div class="footer">Secure VPN Access • %s</div></body></html>`

const dbPath = "/usr/local/etc/xray/bot_db.json"

type BotDB struct {
	Invites map[string]string `json:"invites"`
	Users   map[int64]string  `json:"users"`
	mu      sync.RWMutex
}

var db = &BotDB{
	Invites: make(map[string]string),
	Users:   make(map[int64]string),
}

type Config struct {
	Token  string
	ChatID int64
}

func loadConfig() (*Config, error) {
	file, err := os.Open("/root/.vpn_tg.conf")
	if err != nil { return nil, err }
	defer file.Close()
	cfg := &Config{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "TG_TOKEN=") { cfg.Token = strings.Trim(strings.TrimPrefix(line, "TG_TOKEN="), "\"") }
		if strings.HasPrefix(line, "TG_CHAT_ID=") {
			idStr := strings.Trim(strings.TrimPrefix(line, "TG_CHAT_ID="), "\"")
			cfg.ChatID, _ = strconv.ParseInt(idStr, 10, 64)
		}
	}
	return cfg, nil
}

func loadDB() {
	db.mu.Lock()
	defer db.mu.Unlock()
	data, err := os.ReadFile(dbPath)
	if err == nil { json.Unmarshal(data, db) }
	if db.Invites == nil { db.Invites = make(map[string]string) }
	if db.Users == nil { db.Users = make(map[int64]string) }
}

func saveDB() {
	db.mu.RLock()
	defer db.mu.RUnlock()
	data, _ := json.MarshalIndent(db, "", "  ")
	os.WriteFile(dbPath, data, 0644)
}

func runShell(command string) string {
	out, err := exec.Command("bash", "-c", command).CombinedOutput()
	if err != nil { return fmt.Sprintf("ERROR|%v\n%s", err, string(out)) }
	return string(out)
}

func createPage(name, uuid, subUrl string) {
	htmlContent := fmt.Sprintf(htmlTemplate, name, name, subUrl, subUrl, subUrl, subUrl, time.Now().Format("2006"))
	os.WriteFile(fmt.Sprintf("/var/www/html/sub/%s.html", uuid), []byte(htmlContent), 0644)
}

func genInviteCode() string {
	bytes := make([]byte, 4)
	rand.Read(bytes)
	return "INV-" + strings.ToUpper(hex.EncodeToString(bytes))
}

func main() {
	cfg, err := loadConfig()
	if err != nil || cfg.Token == "" { log.Fatal("Ошибка конфига") }
	loadDB()

	bot, err := tgbotapi.NewBotAPI(cfg.Token)
	if err != nil { log.Panic(err) }

	mainKeyboard := tgbotapi.NewReplyKeyboard(
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📊 Статус"), tgbotapi.NewKeyboardButton("📈 Трафик")),
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("👥 Клиенты"), tgbotapi.NewKeyboardButton("⚙️ Управление")),
	)

	clientsKeyboard := tgbotapi.NewReplyKeyboard(
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📋 Список клиентов"), tgbotapi.NewKeyboardButton("🎟 Создать инвайт")),
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("➕ Добавить клиента"), tgbotapi.NewKeyboardButton("➖ Удалить клиента")),
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("⏳ Ожидающие инвайты"), tgbotapi.NewKeyboardButton("🔙 Назад в меню")),
	)

	manageKeyboard := tgbotapi.NewReplyKeyboard(
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🎭 Смена SNI"), tgbotapi.NewKeyboardButton("🔄 Рестарт кластера")),
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📦 Бекап"), tgbotapi.NewKeyboardButton("🔙 Назад в меню")),
	)

	userKeyboard := tgbotapi.NewReplyKeyboard(
		tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🌍 Моя ссылка"), tgbotapi.NewKeyboardButton("📊 Мой статус")),
	)

	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	adminState := ""

	for update := range updates {
		if update.Message == nil { continue }
		chatID := update.Message.Chat.ID
		text := update.Message.Text
		
		isAdmin := chatID == cfg.ChatID
		
		db.mu.RLock()
		uuidStr, isUser := db.Users[chatID]
		db.mu.RUnlock()

		// ПРОВЕРКА АКТУАЛЬНОСТИ ЮЗЕРА (Синхронизация с Xray)
		if isUser {
			checkCmd := fmt.Sprintf(`grep -q "%s" /usr/local/etc/xray/config.json && echo "OK" || echo "FAIL"`, uuidStr)
			if strings.TrimSpace(runShell(checkCmd)) == "FAIL" {
				db.mu.Lock()
				delete(db.Users, chatID)
				db.mu.Unlock()
				saveDB()
				
				msg := tgbotapi.NewMessage(chatID, "❌ Ваш профиль был удален или деактивирован администратором.")
				msg.ReplyMarkup = tgbotapi.NewRemoveKeyboard(true)
				bot.Send(msg)
				continue
			}
		}

		// Игнорируем чужих, если это не попытка ввода инвайта
		if !isAdmin && !isUser && !strings.HasPrefix(text, "/start INV-") { continue }

		if text == "🔙 Назад в меню" || text == "👥 Клиенты" || text == "⚙️ Управление" {
			adminState = ""
		}

		msg := tgbotapi.NewMessage(chatID, "")

		// --- ОБРАБОТКА ВВОДА АДМИНА (МАШИНА СОСТОЯНИЙ) ---
		if isAdmin && adminState != "" {
			input := strings.TrimSpace(text)
			
			if adminState == "invite" {
				code := genInviteCode()
				db.mu.Lock(); db.Invites[code] = input; db.mu.Unlock(); saveDB()
				adminState = ""
				botName := bot.Self.UserName 
				msg.Text = fmt.Sprintf("✅ Инвайт для %s создан!\n\nПерешлите пользователю это сообщение:\n\n👇 Нажми на ссылку ниже, чтобы получить свой VPN:\nhttps://t.me/%s?start=%s", input, botName, code)
				msg.DisableWebPagePreview = true
				bot.Send(msg)
				continue
				
			} else if adminState == "add" {
				adminState = ""
				bot.Send(tgbotapi.NewMessage(chatID, "⏳ Создаю пользователя "+input+"..."))
				script := fmt.Sprintf(`
					NAME="%s"
					NEW_UUID=$(/usr/local/bin/xray uuid)
					jq --arg id "$NEW_UUID" --arg email "$NAME" '(.inbounds[]? | select(.tag=="client-in") | .settings.clients) += [{"id": $id, "flow": "xtls-rprx-vision", "email": $email}]' /usr/local/etc/xray/config.json > /tmp/xb.json
					if /usr/local/bin/xray run -test -config /tmp/xb.json >/dev/null 2>&1; then mv /tmp/xb.json /usr/local/etc/xray/config.json; systemctl restart xray; else rm -f /tmp/xb.json; echo "ERROR"; exit 1; fi
					DOM=$(ls /etc/letsencrypt/live/ | grep -v README | head -n1); [ -z "$DOM" ] && DOM=$(curl -s4 ifconfig.me)
					LINK="vless://$NEW_UUID@$DOM:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$DOM#$NAME"
					mkdir -p /var/www/html/sub
					echo -n "$LINK" | base64 -w 0 > /var/www/html/sub/$NEW_UUID
					echo "SUCCESS|$NEW_UUID|$DOM"
				`, input)
				res := runShell(script)
				if strings.HasPrefix(res, "SUCCESS") {
					parts := strings.Split(strings.TrimSpace(res), "|")
					subUrl := fmt.Sprintf("https://%s/sub/%s", parts[2], parts[1])
					pageUrl := fmt.Sprintf("https://%s/sub/%s.html", parts[2], parts[1])
					createPage(input, parts[1], subUrl)
					msg.Text = fmt.Sprintf("✅ Пользователь добавлен!\n\n🌍 Ссылка для настройки:\n%s", pageUrl)
				} else {
					msg.Text = "❌ Ошибка создания пользователя."
				}
				bot.Send(msg)
				continue
				
			} else if adminState == "del" {
				adminState = ""
				bot.Send(tgbotapi.NewMessage(chatID, "⏳ Удаляю пользователя "+input+"..."))
				script := fmt.Sprintf(`
					UUID=$(jq -r --arg del "%s" '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | select(.email == $del or .id == $del) | .id' /usr/local/etc/xray/config.json | head -n 1)
					jq --arg del "%s" '(.inbounds[]? | select(.tag=="client-in") | .settings.clients) |= map(select(.id != $del and .email != $del))' /usr/local/etc/xray/config.json > /tmp/xb.json
					if /usr/local/bin/xray run -test -config /tmp/xb.json >/dev/null 2>&1; then
						mv /tmp/xb.json /usr/local/etc/xray/config.json; systemctl restart xray; 
						[ -n "$UUID" ] && rm -f /var/www/html/sub/$UUID /var/www/html/sub/$UUID.html
						echo "SUCCESS|$UUID"
					else rm -f /tmp/xb.json; echo "ERROR"; fi
				`, input, input)
				res := runShell(script)
				if strings.HasPrefix(res, "SUCCESS") {
					deletedUUID := strings.TrimSpace(strings.Split(res, "|")[1])
					db.mu.Lock()
					for chat, uid := range db.Users { if uid == deletedUUID { delete(db.Users, chat) } }
					db.mu.Unlock()
					saveDB()
					msg.Text = "✅ Пользователь успешно удален!"
				} else {
					msg.Text = "❌ Ошибка удаления (возможно, конфиг сломан)."
				}
				bot.Send(msg)
				continue
			}
		}

		// --- ОСНОВНАЯ МАРШРУТИЗАЦИЯ ---
		switch {
		
		// МЕНЮ НАВИГАЦИИ
		case text == "🔙 Назад в меню" && isAdmin:
			msg.Text = "🏠 Главное меню:"
			msg.ReplyMarkup = mainKeyboard

		case text == "👥 Клиенты" && isAdmin:
			msg.Text = "👥 Управление клиентами и инвайтами:"
			msg.ReplyMarkup = clientsKeyboard

		case text == "⚙️ Управление" && isAdmin:
			msg.Text = "⚙️ Настройки сервера и инфраструктуры:"
			msg.ReplyMarkup = manageKeyboard

		// АДМИН: УПРАВЛЕНИЕ КЛИЕНТАМИ И ИНВАЙТАМИ
		case text == "➕ Добавить клиента" && isAdmin:
			adminState = "add"
			msg.Text = "✍️ Введите Имя нового клиента (английскими буквами, без пробелов):"
			
		case text == "➖ Удалить клиента" && isAdmin:
			adminState = "del"
			msg.Text = "✍️ Введите Имя (или UUID) клиента для удаления:"

		case text == "🎟 Создать инвайт" && isAdmin:
			adminState = "invite"
			msg.Text = "✍️ Введите Имя пользователя для инвайта (английскими буквами):"

		case text == "⏳ Ожидающие инвайты" && isAdmin:
			db.mu.RLock()
			count := len(db.Invites)
			res := ""
			if count == 0 {
				res = "Нет ожидающих инвайтов."
			} else {
				res = fmt.Sprintf("⏳ Ожидающие инвайты (%d):\n\n", count)
				for code, name := range db.Invites {
					res += fmt.Sprintf("👤 Для: %s\n🔑 Код: %s\n🗑 Отозвать: /revoke_%s\n\n", name, code, code)
				}
			}
			db.mu.RUnlock()
			msg.Text = res
			
		case strings.HasPrefix(text, "/revoke_INV-") && isAdmin:
			code := strings.TrimSpace(strings.TrimPrefix(text, "/revoke_"))
			db.mu.Lock()
			_, exists := db.Invites[code]
			if exists { delete(db.Invites, code) }
			db.mu.Unlock()
			if exists {
				saveDB()
				msg.Text = "✅ Инвайт " + code + " успешно отозван."
			} else {
				msg.Text = "❌ Инвайт не найден или уже использован."
			}

		// ЛОГИКА ЮЗЕРА: ИНВАЙТ, ССЫЛКА, СТАТУС
		case strings.HasPrefix(text, "/start INV-"):
			code := strings.TrimSpace(strings.TrimPrefix(text, "/start "))
			db.mu.Lock()
			targetName, valid := db.Invites[code]
			db.mu.Unlock()
			
			if !valid {
				msg.Text = "❌ Инвайт-код недействителен или уже использован."
				bot.Send(msg)
				continue
			}

			bot.Send(tgbotapi.NewMessage(chatID, "⏳ Настраиваю твой личный профиль..."))
			
			script := fmt.Sprintf(`
				NAME="%s"
				NEW_UUID=$(/usr/local/bin/xray uuid)
				jq --arg id "$NEW_UUID" --arg email "$NAME" '(.inbounds[]? | select(.tag=="client-in") | .settings.clients) += [{"id": $id, "flow": "xtls-rprx-vision", "email": $email}]' /usr/local/etc/xray/config.json > /tmp/xb.json
				if /usr/local/bin/xray run -test -config /tmp/xb.json >/dev/null 2>&1; then mv /tmp/xb.json /usr/local/etc/xray/config.json; systemctl restart xray; else rm -f /tmp/xb.json; echo "ERROR"; exit 1; fi
				
				DOM=$(ls /etc/letsencrypt/live/ | grep -v README | head -n1); [ -z "$DOM" ] && DOM=$(curl -s4 ifconfig.me)
				LINK="vless://$NEW_UUID@$DOM:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$DOM#$NAME"
				mkdir -p /var/www/html/sub
				echo -n "$LINK" | base64 -w 0 > /var/www/html/sub/$NEW_UUID
				echo "SUCCESS|$NEW_UUID|$DOM"
			`, targetName)
			
			res := runShell(script)
			if strings.HasPrefix(res, "SUCCESS") {
				parts := strings.Split(strings.TrimSpace(res), "|")
				uuid := parts[1]; dom := parts[2]
				subUrl := fmt.Sprintf("https://%s/sub/%s", dom, uuid)
				pageUrl := fmt.Sprintf("https://%s/sub/%s.html", dom, uuid)
				createPage(targetName, uuid, subUrl)
				
				db.mu.Lock()
				db.Users[chatID] = uuid
				delete(db.Invites, code)
				db.mu.Unlock()
				saveDB()
				
				msg.ReplyMarkup = userKeyboard
				msg.Text = fmt.Sprintf("✅ *Профиль создан!*\n\n🌍 Твоя страница подключения:\n\n%s", pageUrl)
				msg.ParseMode = "Markdown"
				msg.DisableWebPagePreview = true
			} else {
				msg.Text = "❌ Произошла ошибка на сервере при создании профиля."
			}

		case text == "🌍 Моя ссылка" && isUser:
			dom := strings.TrimSpace(runShell(`ls /etc/letsencrypt/live/ | grep -v README | head -n1`))
			msg.Text = fmt.Sprintf("🌍 Твоя страница подключения:\n\nhttps://%s/sub/%s.html", dom, uuidStr)
			msg.DisableWebPagePreview = true

		case text == "📊 Мой статус" && isUser:
			email := strings.TrimSpace(runShell(fmt.Sprintf(`jq -r '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | select(.id=="%s") | .email' /usr/local/etc/xray/config.json`, uuidStr)))
			if email == "" || email == "null" { email = "Unknown" }

			statsRaw := runShell(fmt.Sprintf(`/usr/local/bin/xray api statsquery -server=127.0.0.1:10085 -pattern "user>>>%s>>>" 2>&1`, email))
			
			resMsg := fmt.Sprintf("📊 *Твой статус VPN*\n👤 Профиль: `%s`\n\n", email)
			if strings.Contains(statsRaw, "failed") || statsRaw == "" {
				resMsg += "Трафик: `Нет данных`"
			} else {
				down := runShell(fmt.Sprintf(`echo '%s' | grep 'downlink' -A 1 | grep 'value' | grep -o '[0-9]*'`, statsRaw))
				up := runShell(fmt.Sprintf(`echo '%s' | grep 'uplink' -A 1 | grep 'value' | grep -o '[0-9]*'`, statsRaw))
				dVal, _ := strconv.ParseFloat(strings.TrimSpace(down), 64)
				uVal, _ := strconv.ParseFloat(strings.TrimSpace(up), 64)
				resMsg += fmt.Sprintf("🔽 Скачано: `%.2f MB`\n🔼 Загружено: `%.2f MB`", dVal/1048576, uVal/1048576)
			}

			// Безопасная проверка статуса серверов
			srvStat := runShell(`RU=$(systemctl is-active xray 2>/dev/null | grep -q "^active$" && echo "🟢 Работает" || echo "🔴 Сбой"); IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u); T=0; O=0; for I in $IPS; do T=$((T+1)); if nc -z -w 2 "$I" 443 2>/dev/null; then O=$((O+1)); fi; done; EU="🔴 Нет узлов"; if [ "$T" -gt 0 ]; then if [ "$O" -eq "$T" ]; then EU="🟢 Доступны ($O/$T)"; elif [ "$O" -gt 0 ]; then EU="🟡 Частично ($O/$T)"; else EU="🔴 Сбой (0/$T)"; fi; fi; echo -e "\n\n🌍 *Состояние сети:*\n🇷🇺 Точка входа: $RU\n🇪🇺 Зарубежные узлы: $EU"`)
			
			msg.Text = resMsg + srvStat
			msg.ParseMode = "Markdown"

		// --- ОСТАЛЬНЫЕ КОМАНДЫ АДМИНА ---
		case text == "📋 Список клиентов" && isAdmin:
			res := runShell(`jq -r '.inbounds[]? | select(.tag=="client-in") | .settings.clients[] | "👤 \(.email) (ID: \(.id))"' /usr/local/etc/xray/config.json`)
			if res == "" || res == "\n" { res = "Пусто" }
			msg.Text = res

		case text == "📊 Статус" && isAdmin:
			msg.Text = runShell(`CPU=$(top -bn1 | grep load | awk '{printf "%.2f", $(NF-2)}'); RAM=$(free -m | awk 'NR==2{printf "%s/%sMB", $3,$2}'); IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u); NODES=""; for IP in $IPS; do if nc -z -w 2 "$IP" 443 2>/dev/null; then NODES="$NODES\n🟢 $IP - Online"; else NODES="$NODES\n🔴 $IP - Offline"; fi; done; echo -e "🇷🇺 *RU-Мост:*\nCPU: $CPU | RAM: $RAM\n-----------------------\n🇪🇺 *EU-Ноды:*$NODES"`)
			msg.ParseMode = "Markdown"

		case text == "📈 Трафик" && isAdmin:
			msg.Text = runShell(`RAW=$(/usr/local/bin/xray api statsquery -server=127.0.0.1:10085 -pattern "" 2>&1); if [[ -z "$RAW" || "$RAW" == *"failed"* ]]; then echo "⚠️ Нет данных"; else echo "$RAW" | grep -oE 'user>>>[^"]+|"value":\s*"?[0-9]+"?|value:\s*[0-9]+' | sed -E 's/"value":\s*"?|value:\s*//; s/"//g' | awk '/^user>>>/{split($0,a,">>>"); u=a[2]; t=a[4]; getline v; if(t=="downlink") d[u]+=v; if(t=="uplink") up[u]+=v; usrs[u]=1} END{for(u in usrs) printf "👤 %s:\n 🔽 %.2f MB | 🔼 %.2f MB\n", u, d[u]/1048576, up[u]/1048576}'; fi`)

		case text == "🎭 Смена SNI" && isAdmin:
			tagsRaw := runShell(`jq -r '.outbounds[]? | select(.protocol=="vless" and .streamSettings.security=="reality") | .tag' /usr/local/etc/xray/config.json | sed 's/-vless//g; s/-xhttp//g' | sort -u | paste -sd ", "`)
			if tagsRaw == "" || strings.Contains(tagsRaw, "ERROR") { tagsRaw = "Нет доступных EU-нод" }
			msg.Text = fmt.Sprintf("🎭 *Смена SNI (Сайта маскировки)*\n\nДля изменения отправьте команду:\n`/setsni <тег> <новый_домен>`\n\nДоступные ноды: *%s*", strings.TrimSpace(tagsRaw))
			msg.ParseMode = "Markdown"

		case strings.HasPrefix(text, "/setsni ") && isAdmin:
			parts := strings.Split(strings.TrimSpace(text), " ")
			if len(parts) != 3 {
				msg.Text = "⚠️ Неверный формат. Пример: `/setsni eu1 www.samsung.com`"
				bot.Send(msg); continue
			}
			tag := parts[1]; sni := parts[2]
			bot.Send(tgbotapi.NewMessage(chatID, fmt.Sprintf("⏳ Подключаюсь к ноде %s для смены SNI на %s...", tag, sni)))
			
			script := fmt.Sprintf(`
				TAG="%s"; NEW_SNI="%s"
				EU_IP=$(jq -r --arg t "${TAG}-vless" '.outbounds[]? | select(.tag==$t) | .settings.vnext[0].address' /usr/local/etc/xray/config.json)
				if [ -z "$EU_IP" ] || [ "$EU_IP" == "null" ]; then echo "ERROR|Нода не найдена"; exit 0; fi
				jq --arg t1 "${TAG}-vless" --arg t2 "${TAG}-xhttp" --arg sni "$NEW_SNI" '.outbounds |= map(if .tag == $t1 or .tag == $t2 then .streamSettings.realitySettings.serverName = $sni else . end)' /usr/local/etc/xray/config.json > /tmp/xray_ru_sni.json
				ssh -o StrictHostKeyChecking=no root@$EU_IP "bash -s" << REMOTE_EOF
					jq --arg sni "$NEW_SNI" '.inbounds |= map(if .streamSettings.security == "reality" then .streamSettings.realitySettings.dest = (\$sni + ":443") | .streamSettings.realitySettings.serverNames = [\$sni] else . end)' /usr/local/etc/xray/config.json > /tmp/xray_eu_sni.json && mv /tmp/xray_eu_sni.json /usr/local/etc/xray/config.json && systemctl restart xray
REMOTE_EOF
				if [ $? -eq 0 ]; then mv /tmp/xray_ru_sni.json /usr/local/etc/xray/config.json; systemctl restart xray; echo "SUCCESS|$EU_IP"; else rm -f /tmp/xray_ru_sni.json; echo "ERROR|Ошибка на EU-ноде"; fi
			`, tag, sni)
			res := runShell(script)
			if strings.HasPrefix(res, "SUCCESS") { msg.Text = fmt.Sprintf("✅ *Готово!*\nSNI изменен на `%s`.", sni) } else { msg.Text = "❌ Ошибка: " + res }
			msg.ParseMode = "Markdown"

		case text == "🔄 Рестарт кластера" && isAdmin:
			bot.Send(tgbotapi.NewMessage(chatID, "🔄 Выполняю безопасную перезагрузку всех EU-серверов и RU-моста..."))
			go func() {
				runShell(`IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u); for IP in $IPS; do ssh -o StrictHostKeyChecking=no root@$IP "/sbin/reboot" < /dev/null & done; sleep 3; /sbin/reboot`)
			}()
			continue

		case text == "📦 Бекап" && isAdmin:
			bot.Send(tgbotapi.NewMessage(chatID, "⏳ Собираю бекап..."))
			bFile := fmt.Sprintf("/tmp/backup_%d.tar.gz", time.Now().Unix())
			runShell(fmt.Sprintf(`docker stop ssantifilter >/dev/null 2>&1; tar -czf %s -C / root/.ssh usr/local/etc/xray etc/letsencrypt etc/nginx/sites-available/default var/www/html data/ssantifilter root/.vpn_tg.conf 2>/dev/null; docker start ssantifilter >/dev/null 2>&1`, bFile))
			bot.Send(tgbotapi.NewDocument(chatID, tgbotapi.FilePath(bFile)))
			os.Remove(bFile)
			continue

		case text == "/start":
			if isAdmin {
				msg.Text = "🤖 *VPN Bridge Bot*\nИспользуй кнопки ниже."
				msg.ReplyMarkup = mainKeyboard
			} else {
				msg.Text = "👋 Добро пожаловать! Если у вас есть инвайт-ссылка, просто перейдите по ней."
			}
			msg.ParseMode = "Markdown"

		default:
			continue
		}
		
		if msg.Text != "" { bot.Send(msg) }
	}
}
GO_EOF

    echo "⏳ 3/4 Компиляция бинарного файла..."
    GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /usr/local/bin/vpn-bot main.go

    echo "🧹 Уборка временных файлов компилятора..."
    rm -rf /usr/local/go /usr/src/vpn-bot /tmp/go1.21.6.linux-amd64.tar.gz
    sed -i '/\/usr\/local\/go\/bin/d' ~/.profile 2>/dev/null

    echo "⏳ 4/4 Настройка Systemd сервиса..."
    cat <<EOF > /etc/systemd/system/vpn-tg-bot.service
[Unit]
Description=VPN Bridge Telegram Bot
After=network.target xray.service docker.service

[Service]
ExecStart=/usr/local/bin/vpn-bot
Restart=always
RestartSec=10
User=root
MemoryLimit=100M
CPUQuota=20%
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-tg-bot.service
    systemctl restart vpn-tg-bot.service
    
    echo "✅ Бот обновлен! Новые функции инвайтов, статуса и меню активны."
    read -p "Нажми Enter..." DUMMY
}

show_logs() {
    echo "📜 ПРОСМОТР ЛОГОВ (Последние 30 строк)"
    echo "1) Xray (Ядро VPN)"
    echo "2) Nginx (Веб-сервер / Заглушка)"
    echo "3) SSAntifilter (Веб-панель)"
    read -p "Выбор: " L_C
    echo "---------------------------------------------------------"
    case $L_C in
        1) journalctl -u xray -n 30 --no-pager ;;
        2) tail -n 30 /var/log/nginx/error.log 2>/dev/null || echo "Ошибок Nginx нет." ;;
        3) docker logs --tail 30 ssantifilter 2>/dev/null ;;
        *) echo "Отмена." ;;
    esac
}

show_stats() {
    echo "📊 СТАТИСТИКА ТРАФИКА (с момента последнего рестарта службы Xray)"
    
    if ! grep -q "StatsService" /usr/local/etc/xray/config.json 2>/dev/null; then
        echo "⚠️ В текущем конфиге не включен сбор статистики."
        read -p "Включить его сейчас? (y/n): " P_S
        if [ "$P_S" == "y" ]; then
            jq '.stats = {} | .api = {"tag": "api", "services": ["StatsService"]} | .policy = {"levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}} | .inbounds += [{"tag": "api-in", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}] | .routing.rules = [{"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"}] + .routing.rules' /usr/local/etc/xray/config.json > /tmp/xray_patch.json
            if xray run -test -config /tmp/xray_patch.json >/dev/null 2>&1; then
                mv /tmp/xray_patch.json /usr/local/etc/xray/config.json
                systemctl restart xray
                echo "✅ Сбор статистики включен! Данные появятся после первых подключений."
            else
                echo "❌ Ошибка интеграции конфига."
                rm -f /tmp/xray_patch.json
            fi
        fi
        return
    fi

    local RAW=$(/usr/local/bin/xray api statsquery -server=127.0.0.1:10085 2>&1)
    
    if [[ -z "$RAW" || "$RAW" == *"failed"* || "$RAW" == *"error"* ]]; then 
        echo "   Нет данных или порт API еще не инициализирован."
        return
    fi

    echo "$RAW" | jq -r '.stat[]? | select(.name | startswith("user>>>")) | "\(.name | split(">>>")[1]) \(.name | split(">>>")[3]) \(.value)"' | awk '
    {
        user = $1
        type = $2
        val = $3
        users[user] = 1
        if (type == "downlink") down[user] += val
        if (type == "uplink") up[user] += val
    }
    END {
        count = 0
        for (u in users) {
            count++
            d_mb = down[u] / 1048576
            u_mb = up[u] / 1048576
            printf "👤 %s:\n   🔽 Скачано: %.2f MB\n   🔼 Загружено: %.2f MB\n", u, d_mb, u_mb
        }
        if (count == 0) print "   Пока нет данных о трафике пользователей."
    }'
}

update_core_and_geo() {
    echo "⏳ Обновление Xray и баз GeoIP/Geosite на RU-мосте..."
    bash -c "$(curl -L https://github.com/sud0-i/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    mkdir -p /usr/local/share/xray
    curl -sL "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" -o /usr/local/share/xray/geoip.dat
    curl -sL "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" -o /usr/local/share/xray/geosite.dat
    systemctl restart xray
    
    if [ -f /usr/local/etc/xray/config.json ]; then
        local IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u)
        for IP in $IPS; do
            echo "⏳ Отправка команды обновления на удаленную EU-ноду: $IP..."
            ssh -o StrictHostKeyChecking=no root@$IP "bash -c \"\$(curl -L https://github.com/sud0-i/Xray-install/raw/main/install-release.sh)\" @ install >/dev/null 2>&1 && mkdir -p /usr/local/share/xray && curl -sL https://github.com/v2fly/geoip/releases/latest/download/geoip.dat -o /usr/local/share/xray/geoip.dat && curl -sL https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -o /usr/local/share/xray/geosite.dat && systemctl restart xray" < /dev/null
        done
    fi
    echo "✅ Вся инфраструктура (Ядро + Базы) успешно обновлена!"
}

toggle_autostart() {
    echo -e "\n⚙️ НАСТРОЙКА АВТОЗАПУСКА ПРИ ВХОДЕ ПО SSH"
    local BASHRC="$HOME/.bashrc"
    local SCRIPT_PATH=$(readlink -f "$0")
    local MARKER="# VPN_BRIDGE_AUTOSTART"
    local AUTOSTART_LINE="[[ \$- == *i* ]] && bash \"$SCRIPT_PATH\" $MARKER"

    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        grep -v "$MARKER" "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
        echo "🔴 Автозапуск ОТКЛЮЧЕН. При входе по SSH будет открываться обычная консоль."
    else
        echo "$AUTOSTART_LINE" >> "$BASHRC"
        echo "🟢 Автозапуск ВКЛЮЧЕН. Меню будет появляться сразу при подключении к серверу."
    fi
}

tg_backup() {
    echo "📦 Подготовка полного бекапа сервера..."
    if [ ! -f ~/.vpn_tg.conf ]; then
        echo "⚠️ Telegram-бот не настроен."
        read -p "Введи токен бота (HTTP API): " TG_TOKEN
        read -p "Введи свой Chat ID: " TG_CHAT_ID
        TG_TOKEN=$(echo "$TG_TOKEN" | tr -d ' \r\n')
        TG_CHAT_ID=$(echo "$TG_CHAT_ID" | tr -d ' \r\n')
        echo "TG_TOKEN=\"$TG_TOKEN\"" > ~/.vpn_tg.conf
        echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> ~/.vpn_tg.conf
    fi
    source ~/.vpn_tg.conf

    BACKUP_FILE="/tmp/vpn_backup_$(date +%F_%H-%M).tar.gz"
    docker stop ssantifilter >/dev/null 2>&1

    PATHS_TO_BACKUP=""
    for p in /root/.ssh /usr/local/etc/xray /etc/letsencrypt /etc/nginx/sites-available/default /var/www/html /data/ssantifilter /root/.vpn_tg.conf; do
        if [ -e "$p" ]; then PATHS_TO_BACKUP="$PATHS_TO_BACKUP ${p#/}"; fi
    done

    if [ -z "$PATHS_TO_BACKUP" ]; then
        echo "❌ Ошибка: Нет данных для бекапа!"
        docker start ssantifilter >/dev/null 2>&1
        return 1
    fi

    tar -czf "$BACKUP_FILE" -C / $PATHS_TO_BACKUP 2>/dev/null
    docker start ssantifilter >/dev/null 2>&1
    
    if [ ! -f "$BACKUP_FILE" ]; then echo "❌ Ошибка создания tar."; return 1; fi

    echo "⏳ Отправка архива в Telegram..."
    MY_IP=$(curl -s4 ifconfig.me)
    TG_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F caption="🔐 ПОЛНЫЙ БЕКАП VPN BRIDGE (IP: ${MY_IP})" \
        -F document=@"${BACKUP_FILE}")
    
    if echo "$TG_RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Бекап успешно отправлен в Telegram!"
    else
        echo "❌ Ошибка отправки! Ответ сервера Telegram:"
        echo "$TG_RESPONSE" | jq . 2>/dev/null || echo "$TG_RESPONSE"
    fi
    rm -f "$BACKUP_FILE"
}

restore_from_backup() {
    echo "♻️ ВОССТАНОВЛЕНИЕ МОСТА ИЗ БЕКАПА"
    read -p "Укажи полный путь к файлу архива (например, /root/vpn_backup.tar.gz): " BACKUP_PATH
    
    if [ ! -f "$BACKUP_PATH" ]; then echo "❌ Файл не найден!"; return 1; fi

    echo "⏳ 1/6 Остановка служб и очистка..."
    systemctl stop nginx xray vpn-tg-bot >/dev/null 2>&1
    if command -v docker &> /dev/null; then docker stop ssantifilter >/dev/null 2>&1; fi
    
    # Предварительная установка зависимостей, если это чистый сервер
    apt-get update -q && apt-get install -yq jq curl openssl socat nginx certbot python3-certbot-nginx tar docker.io >/dev/null 2>&1

    echo "⏳ 2/6 Распаковка данных..."
    tar -xzf "$BACKUP_PATH" -C / 2>/dev/null

    # Определяем старый домен из конфига Nginx
    OLD_DOMAIN=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v "^README$" | head -n 1)
    [ -z "$OLD_DOMAIN" ] && OLD_DOMAIN="Не_определен"

    echo "---------------------------------------------------------"
    echo "📂 В бекапе найден домен: $OLD_DOMAIN"
    echo "1) ✅ Оставить этот домен (восстановить как было)"
    echo "2) 🔄 ПЕРЕЕХАТЬ НА НОВЫЙ ДОМЕН (если старый забанен)"
    echo "---------------------------------------------------------"
    read -p "Твой выбор: " DOM_ACTION

    if [ "$DOM_ACTION" == "2" ]; then
        read -p "Введи НОВЫЙ домен (например, new-vpn.ru): " NEW_DOMAIN
        read -p "Email для сертификатов: " EMAIL
        
        echo "⏳ Миграция на $NEW_DOMAIN..."
        
        # 1. Удаляем старые сертификаты
        rm -rf /etc/letsencrypt/live/$OLD_DOMAIN 2>/dev/null
        rm -rf /etc/letsencrypt/archive/$OLD_DOMAIN 2>/dev/null
        rm -rf /etc/letsencrypt/renewal/$OLD_DOMAIN.conf 2>/dev/null
        
        # 2. Получаем новые
        certbot certonly --standalone -d $NEW_DOMAIN -m $EMAIL --agree-tos -n
        
        if [ ! -f "/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem" ]; then
            echo "❌ Ошибка получения сертификата! Проверь, что домен направлен на этот IP."
            return 1
        fi
        
        # 3. Обновляем Nginx
        sed -i "s/$OLD_DOMAIN/$NEW_DOMAIN/g" /etc/nginx/sites-available/default
        
        # 4. Обновляем сертификаты Xray
        mkdir -p /var/lib/xray/cert
        cp -L /etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem
        cp -L /etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem
        chmod 644 /var/lib/xray/cert/*.pem
        
        # 5. ПЕРЕГЕНЕРАЦИЯ ПОДПИСОК (Самое важное)
        echo "⏳ Перегенерация ссылок для пользователей..."
        rm -rf /var/www/html/sub/*
        mkdir -p /var/www/html/sub
        
        # Функция генерации HTML (встроенная для миграции)
        mig_gen_html() {
            local U=$1; local ID=$2; local URL="https://$NEW_DOMAIN/sub/$2"
            cat <<EOF > /var/www/html/sub/$ID.html
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>VPN: $U</title><style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px;text-align:center}.card{background:#1e1e1e;padding:30px;border-radius:16px;max-width:400px;width:100%}.btn{display:block;width:100%;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold;font-size:16px;box-sizing:border-box}.btn-ios{background:#007AFF;color:#fff}.btn-android{background:#3DDC84;color:#000}.btn-win{background:#00A4EF;color:#fff}.raw-link{background:#111;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;color:#666;word-break:break-all;margin-top:10px;user-select:all}.apps{background:#2a2a2a;padding:15px;border-radius:12px;margin-bottom:20px;text-align:left;font-size:14px}.apps a{color:#4da6ff;text-decoration:none;display:block;margin-bottom:8px}.apps a:hover{text-decoration:underline}</style></head><body><div class="card"><h1>🔑 Привет, $U!</h1><div class="apps"><b>Шаг 1. Установи приложение:</b><br><br><a href="https://apps.apple.com/us/app/v2raytun/id6476628951">🍏 iOS: V2rayTun</a><a href="https://play.google.com/store/apps/details?id=com.v2raytun.android">🤖 Android: V2rayTun</a><a href="https://github.com/hiddify/hiddify-next/releases">💻 PC/Mac: Hiddify Next</a></div><p><b>Шаг 2. Нажми для настройки:</b></p><a href="v2raytun://import/$URL" class="btn btn-win">🚀 Подключить V2rayTun</a><a href="hiddify://install-config?url=$URL" class="btn btn-android">🤖 Подключить Hiddify</a><a href="v2box://install-sub?url=$URL" class="btn btn-ios">🍏 Подключить V2Box</a><p style="font-size:12px;margin-top:20px;">Ручная настройка (скопируй ссылку):</p><div class="raw-link" onclick="navigator.clipboard.writeText(this.innerText); alert('Скопировано!');">$URL</div></div></body></html>
EOF
        }

        # Читаем пользователей из восстановленного JSON
        jq -c '.inbounds[]? | select(.tag=="client-in") | .settings.clients[]' /usr/local/etc/xray/config.json | while read -r client; do
            UUID=$(echo "$client" | jq -r '.id')
            EMAIL=$(echo "$client" | jq -r '.email')
            
            # Генерируем новую ссылку
            L_NEW="vless://$UUID@$NEW_DOMAIN:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$NEW_DOMAIN#$EMAIL"
            
            # Записываем файлы
            echo -n "$L_NEW" | base64 -w 0 > /var/www/html/sub/$UUID
            mig_gen_html "$EMAIL" "$UUID"
            echo "   ✅ Обновлен: $EMAIL"
        done
        
        # Обновляем хук обновления сертификатов
        cat <<EOF > /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh
#!/bin/bash
cp -L /etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem
cp -L /etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem
chmod 644 /var/lib/xray/cert/*.pem; chown -R nobody:nogroup /var/lib/xray/cert; systemctl restart xray
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh

    else
        echo "⏳ Восстанавливаю старый домен ($OLD_DOMAIN)..."
        # Восстанавливаем сертификаты Xray из бекапа (если они там были)
        # Если нет, просто копируем из letsencrypt
        if [ -f "/etc/letsencrypt/live/$OLD_DOMAIN/fullchain.pem" ]; then
            mkdir -p /var/lib/xray/cert
            cp -L /etc/letsencrypt/live/$OLD_DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem
            cp -L /etc/letsencrypt/live/$OLD_DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem
        fi
    fi

    echo "⏳ 3/6 Восстановление прав доступа..."
    chmod 700 /root/.ssh 2>/dev/null
    chmod 600 /root/.ssh/id_rsa 2>/dev/null
    chown -R 1000:1000 /data/ssantifilter 2>/dev/null
    chown -R nobody:nogroup /var/lib/xray/cert 2>/dev/null

    echo "⏳ 4/6 Настройка сети и фаервола..."
    grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.d/99-vpn.conf 2>/dev/null || echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-vpn.conf
    sysctl --system >/dev/null 2>&1
    ufw --force reset >/dev/null 2>&1; ufw default deny incoming; ufw default allow outgoing
    ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable >/dev/null 2>&1

    echo "⏳ 5/6 Запуск служб..."
    # Убеждаемся, что Xray установлен
    [ ! -f /usr/local/bin/xray ] && bash -c "$(curl -L https://github.com/sud0-i/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    systemctl restart nginx
    systemctl restart xray
    if [ -f /etc/systemd/system/vpn-tg-bot.service ]; then systemctl restart vpn-tg-bot; fi
    
    SECRET=$(openssl rand -hex 32)
    docker rm -f ssantifilter 2>/dev/null
    docker run -d --name ssantifilter --restart=unless-stopped -e PORT=8090 -e SESSION_SECRET_KEY="$SECRET" -v /data/ssantifilter/rawdata:/app/rawdata -p 127.0.0.1:8090:8090 sud0i/ssantifilter:latest >/dev/null 2>&1

    echo "⏳ 6/6 Финализация..."
    sleep 5
    
    echo "✅ СИСТЕМА УСПЕШНО ВОССТАНОВЛЕНА!"
    if [ "$DOM_ACTION" == "2" ]; then
        echo "⚠️  ВНИМАНИЕ: Произошла смена домена на $NEW_DOMAIN"
        echo "👉 Зайди в Telegram-бота и запроси новые ссылки для пользователей."
        verify_dns_propagation "$NEW_DOMAIN"
    else
        verify_dns_propagation "$OLD_DOMAIN"
    fi
}

speedtest_bridge() {
    echo -e "\n⚡ ЗАМЕР СКОРОСТИ МЕЖДУ RU И EU (iperf3)"
    local IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u)
    if [ -z "$IPS" ]; then echo "❌ Нет подключенных удаленных серверов."; read -p "Нажми Enter..."; return; fi
    
    echo "⏳ Устанавливаю утилиту iperf3 локально..."
    apt-get install -yq iperf3 >/dev/null 2>&1

    for IP in $IPS; do
        echo "---------------------------------------------------------"
        echo "🌐 Настраиваю EU-ноду ($IP) для теста..."
        ssh -o StrictHostKeyChecking=no root@$IP "apt-get install -yq iperf3 >/dev/null 2>&1 && ufw allow 5201/tcp >/dev/null 2>&1 && killall iperf3 2>/dev/null; iperf3 -s -D" < /dev/null
        
        echo "🚀 Тест 1/2: Скачивание (EU -> RU)..."
        iperf3 -c "$IP" -O 1 -t 5 -R | grep -E "sender|receiver"
        
        echo "🚀 Тест 2/2: Загрузка (RU -> EU)..."
        iperf3 -c "$IP" -O 1 -t 5 | grep -E "sender|receiver"
        
        echo "🧹 Уборка на EU-ноде..."
        ssh -o StrictHostKeyChecking=no root@$IP "killall iperf3 2>/dev/null && ufw delete allow 5201/tcp >/dev/null 2>&1" < /dev/null
    done
    echo "---------------------------------------------------------"
    read -p "Нажми Enter для возврата в меню..." DUMMY
}

update_script() {
    echo -e "\n🔄 ОБНОВЛЕНИЕ СКРИПТА BRIDGE MASTER"
    read -p "Скачать последнюю версию с GitHub? (y/n): " UP_C
    if [ "$UP_C" == "y" ]; then
        echo "⏳ Скачиваю обновление..."
        local SCRIPT_PATH=$(readlink -f "$0")
        wget -qO "$SCRIPT_PATH.tmp" "https://raw.githubusercontent.com/sud0-i/BridgeMaster/main/bridgeStable.sh"
        if [ -s "$SCRIPT_PATH.tmp" ]; then
            mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo "✅ Скрипт успешно обновлен!"
            echo "🚀 Перезапуск..."
            sleep 2
            exec "$SCRIPT_PATH"
        else
            echo "❌ Ошибка при скачивании файла с GitHub."
            rm -f "$SCRIPT_PATH.tmp"
        fi
    fi
}

update_script_test() {
    echo -e "\n🔄 ОБНОВЛЕНИЕ СКРИПТА BRIDGE MASTER"
    read -p "Скачать последнюю тестовую версию с GitHub? (y/n): " UP_C
    if [ "$UP_C" == "y" ]; then
        echo "⏳ Скачиваю обновление..."
        local SCRIPT_PATH=$(readlink -f "$0")
        wget -qO "$SCRIPT_PATH.tmp" "https://raw.githubusercontent.com/sud0-i/BridgeMaster/main/bridgeUnstable.sh"
        if [ -s "$SCRIPT_PATH.tmp" ]; then
            mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo "✅ Скрипт успешно обновлен!"
            echo "🚀 Перезапуск..."
            sleep 2
            exec "$SCRIPT_PATH"
        else
            echo "❌ Ошибка при скачивании файла с GitHub."
            rm -f "$SCRIPT_PATH.tmp"
        fi
    fi
}

install_ssantifilter() {
    echo "⏳ Устанавливаю Docker и SSAntifilter..."
    mkdir -p /data/ssantifilter/rawdata
    chown -R 1000:1000 /data/ssantifilter
    SECRET=$(openssl rand -hex 32)
    
    docker rm -f ssantifilter 2>/dev/null
    docker run -d --name ssantifilter --restart=unless-stopped -e PORT=8090 -e SESSION_SECRET_KEY="$SECRET" -v /data/ssantifilter/rawdata:/app/rawdata -p 127.0.0.1:8090:8090 sud0i/ssantifilter:latest >/dev/null 2>&1
    
    echo "⏳ Ожидаю генерации пароля (10 сек)..."
    sleep 10
    ADMIN_PASS=$(docker logs ssantifilter 2>&1 | grep -i "password" | awk -F'password:' '{print $2}' | tr -d ' \r\n')
    echo "✅ SSAntifilter запущен. Пароль админа: $ADMIN_PASS"
}

setup_eu_node() {
    local IP=$1; local SNI=$2; local PASS=$3; local NODE_NAME=$4
    echo "⏳ [$NODE_NAME] Настраиваю удаленный EU сервер $IP..."
    
    export SSHPASS="$PASS"
    sshpass -e ssh-copy-id -o StrictHostKeyChecking=no root@$IP >/dev/null 2>&1
    
    REMOTE_RESULT=$(sshpass -e ssh -o StrictHostKeyChecking=no root@$IP "bash -s" "$SNI" << 'REMOTE_EOF'
        TARGET_SITE=$1
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q && apt-get install -yq curl socat jq openssl ufw gnupg >/dev/null 2>&1
        
        grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.d/99-vpn.conf 2>/dev/null || echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-vpn.conf
        sysctl --system >/dev/null 2>&1

        ufw --force reset >/dev/null 2>&1; ufw default deny incoming >/dev/null 2>&1; ufw default allow outgoing >/dev/null 2>&1
        ufw allow 22/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; ufw allow 4433/tcp >/dev/null 2>&1; ufw allow 5000/tcp >/dev/null 2>&1; ufw allow 5000/udp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1

        if [ ! -x /usr/bin/warp-cli ]; then
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            source /etc/os-release
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -q && apt-get install -yq cloudflare-warp >/dev/null 2>&1
            
            warp-cli --accept-tos registration new >/dev/null 2>&1
            warp-cli --accept-tos mode proxy >/dev/null 2>&1
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
            warp-cli --accept-tos connect >/dev/null 2>&1
        fi

        [ ! -f /usr/local/bin/xray ] && bash -c "$(curl -L https://github.com/sud0-i/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        MY_UUID=$(/usr/local/bin/xray uuid); MY_SS_PASS=$(openssl rand -base64 16); XHTTP_PATH=$(openssl rand -hex 6)
        
        K_TCP=$(/usr/local/bin/xray x25519); PRV_TCP=$(echo "$K_TCP" | grep -iE "PrivateKey" | awk -F':' '{print $2}' | tr -d ' \n\r'); PUB_TCP=$(echo "$K_TCP" | grep -iE "Password" | awk -F':' '{print $2}' | tr -d ' \n\r'); SID_TCP=$(openssl rand -hex 4 | tr -d ' \n\r')
        K_XH=$(/usr/local/bin/xray x25519); PRV_XH=$(echo "$K_XH" | grep -iE "PrivateKey" | awk -F':' '{print $2}' | tr -d ' \n\r'); PUB_XH=$(echo "$K_XH" | grep -iE "Password" | awk -F':' '{print $2}' | tr -d ' \n\r'); SID_XH=$(openssl rand -hex 4 | tr -d ' \n\r')

        cat <<CFG > /tmp/xray_eu.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "ss-in", "port": 5000, "protocol": "shadowsocks", "settings": { "method": "2022-blake3-aes-128-gcm", "password": "$MY_SS_PASS", "network": "tcp,udp" } },
    { "tag": "vless-tcp-in", "port": 443, "protocol": "vless", "settings": { "clients": [ { "id": "$MY_UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "$TARGET_SITE:443", "serverNames": ["$TARGET_SITE"], "privateKey": "$PRV_TCP", "shortIds": ["$SID_TCP"] } } },
    { "tag": "vless-xhttp-in", "port": 4433, "protocol": "vless", "settings": { "clients": [ { "id": "$MY_UUID" } ], "decryption": "none" }, "streamSettings": { "network": "xhttp", "security": "reality", "xhttpSettings": { "path": "/$XHTTP_PATH", "mode": "auto" }, "realitySettings": { "show": false, "dest": "$TARGET_SITE:443", "serverNames": ["$TARGET_SITE"], "privateKey": "$PRV_XH", "shortIds": ["$SID_XH"] } } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" }, { "tag": "warp", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } }, { "tag": "block", "protocol": "blackhole" } ],
  "routing": { "domainStrategy": "IPIfNonMatch", "rules": [ { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }, { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }, { "type": "field", "domain": ["geosite:google", "geosite:openai", "domain:ru", "geosite:category-ru", "geoip:ru"], "outboundTag": "warp" } ] }
}
CFG
        /usr/local/bin/xray run -test -config /tmp/xray_eu.json >/dev/null 2>&1 || { echo "VPN_ERROR|Config invalid"; exit 1; }
        mv /tmp/xray_eu.json /usr/local/etc/xray/config.json
        systemctl restart xray
        
        mkdir -p /etc/ssh/sshd_config.d
        echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/99-vpn-disable-pass.conf
        sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config 2>/dev/null
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        
        echo "VPN_DATA|$MY_UUID|$MY_SS_PASS|$PUB_TCP|$SID_TCP|$PUB_XH|$SID_XH|$XHTTP_PATH"
REMOTE_EOF
)
    local DATA_LINE=$(echo "$REMOTE_RESULT" | grep "VPN_DATA")
    if [ -z "$DATA_LINE" ]; then echo "❌ [$NODE_NAME] Ошибка настройки! Лог: $REMOTE_RESULT"; exit 1; fi
    echo "$DATA_LINE"
}

# ------------------------------------------------------------------------------
# ФУНКЦИИ УПРАВЛЕНИЯ ИНФРАСТРУКТУРОЙ
# ------------------------------------------------------------------------------
deploy_new_bridge() {
    read -p "🌐 Введи домен RU-сервера: " DOMAIN
    verify_dns_propagation "$DOMAIN"
    read -p "✉️ Email для SSL: " EMAIL
    read -p "[EU-1] IP: " EU1_IP
    read -p "[EU-1] SNI [swdist.apple.com]: " EU1_SNI; EU1_SNI=${EU1_SNI:-swdist.apple.com}; EU1_SNI=$(echo "$EU1_SNI" | tr -d ' \r\n')
    read -s -p "[EU-1] Пароль от root: " EU1_PASS; echo ""

    # Сбрасываем старый SSH ключ (на случай, если сервер переустанавливался у хостера)
    ssh-keygen -R "$EU1_IP" >/dev/null 2>&1

    RAW=$(setup_eu_node "$EU1_IP" "$EU1_SNI" "$EU1_PASS" "EU-1")
    E1_U=$(echo "$RAW" | awk -F'|' '{print $2}' | tr -d ' \r\n'); E1_S=$(echo "$RAW" | awk -F'|' '{print $3}' | tr -d ' \r\n')
    E1_PT=$(echo "$RAW" | awk -F'|' '{print $4}' | tr -d ' \r\n'); E1_ST=$(echo "$RAW" | awk -F'|' '{print $5}' | tr -d ' \r\n')
    E1_PX=$(echo "$RAW" | awk -F'|' '{print $6}' | tr -d ' \r\n'); E1_SX=$(echo "$RAW" | awk -F'|' '{print $7}' | tr -d ' \r\n')
    E1_XP=$(echo "$RAW" | awk -F'|' '{print $8}' | tr -d ' \r\n')

    echo "⏳ Настраиваю RU-сервер..."
    grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.d/99-vpn.conf 2>/dev/null || echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-vpn.conf
    sysctl --system >/dev/null 2>&1
    ufw --force reset >/dev/null 2>&1; ufw default deny incoming >/dev/null 2>&1; ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1; ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        systemctl stop nginx 2>/dev/null
        echo "⏳ Получаю SSL сертификат (Let's Encrypt)..."
        certbot certonly --standalone -d $DOMAIN -m $EMAIL --agree-tos -n
        
        # ЖЕСТКАЯ ПРОВЕРКА: Если сертификат не появился, прерываем установку!
        if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Certbot не смог выпустить сертификат SSL!"
            echo "👉 Если используешь Cloudflare, выключи 'Оранжевое облако' (сделай DNS only) на время установки."
            systemctl start nginx 2>/dev/null
            return
        fi
    fi
    mkdir -p /var/lib/xray/cert
    cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem
    cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem
    chmod 755 /var/lib/xray /var/lib/xray/cert && chmod 644 /var/lib/xray/cert/*.pem
    chown -R nobody:nogroup /var/lib/xray/cert

    cat <<EOF > /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh
#!/bin/bash
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem
cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem
chmod 644 /var/lib/xray/cert/*.pem; chown -R nobody:nogroup /var/lib/xray/cert; systemctl restart xray
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh

    mkdir -p /var/www/html
    cat <<EOF > /var/www/html/index.html
<!DOCTYPE html><html><head><title>Zabbix</title><style>body{background:#020202;color:#e0e0e0;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}.box{background:#2b2b2b;padding:20px;width:300px}.input{width:100%;padding:8px;margin-bottom:10px;background:#383838;border:1px solid #4f4f4f;color:#fff;box-sizing:border-box}.btn{width:100%;padding:10px;background:#0275b8;color:#fff;border:none}</style></head><body><div class="box"><h3>Monitoring System</h3><input type="text" class="input" placeholder="Admin"><input type="password" class="input" placeholder="Password"><button class="btn">Sign in</button></div></body></html>
EOF

    mkdir -p /var/www/html/sub
    cat <<EOF > /etc/nginx/sites-available/default
server { listen 127.0.0.1:8080 proxy_protocol default_server; listen 127.0.0.1:8081 proxy_protocol http2 default_server; server_name _; set_real_ip_from 127.0.0.1; real_ip_header proxy_protocol; root /var/www/html; index index.html;
    location / { try_files \$uri \$uri/ =404; }
    
    # РАЗДАЧА ПОДПИСОК И HTML СТРАНИЦ
    location /sub/ {
        alias /var/www/html/sub/;
        include /etc/nginx/mime.types;
        default_type "text/plain; charset=utf-8";
        add_header Content-Disposition "inline";
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }

    location /antifilter/ { proxy_pass http://127.0.0.1:8090/; proxy_redirect / /antifilter/; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    location ~ ^/(login|logout|save|update|ws|api|static) { proxy_pass http://127.0.0.1:8090; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    location ~ \.(dat|list|yaml)$ { proxy_pass http://127.0.0.1:8090; proxy_set_header Host \$host; }
}
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
EOF
    systemctl restart nginx

    [ ! -f /usr/local/bin/xray ] && bash -c "$(curl -L https://github.com/sud0-i/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    CLIENT_UUID=$(xray uuid)

    cat <<EOF > /tmp/ru_base.json
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": { "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } }, "system": { "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true } },
  "inbounds": [
    { "tag": "api-in", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },
    { "tag": "client-in", "port": 443, "protocol": "vless", "settings": { "clients": [ { "id": "$CLIENT_UUID", "flow": "xtls-rprx-vision", "email": "Admin" } ], "decryption": "none", "fallbacks": [ { "alpn": "h2", "dest": 8081, "xver": 1 }, { "dest": 8080, "xver": 1 } ] }, "streamSettings": { "network": "tcp", "security": "tls", "tlsSettings": { "alpn": ["h2", "http/1.1"], "certificates": [ { "certificateFile": "/var/lib/xray/cert/fullchain.pem", "keyFile": "/var/lib/xray/cert/privkey.pem" } ] } } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" }, { "tag": "block", "protocol": "blackhole" } ],
  "observatory": { "subjectSelector": [], "probeUrl": "https://www.google.com/generate_204", "probeInterval": "1m", "enableConcurrency": true },
  "routing": { "balancers": [ { "tag": "euro-balancer", "selector": [], "strategy": { "type": "leastPing" } } ], "rules": [ { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }, { "type": "field", "inboundTag": ["client-in"], "balancerTag": "euro-balancer" }, { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }, { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" } ] }
}
EOF
    cat <<EOF > /tmp/eu_nodes.json
[
  { "tag": "eu1-ss", "protocol": "shadowsocks", "settings": { "servers": [ { "address": "$EU1_IP", "port": 5000, "method": "2022-blake3-aes-128-gcm", "password": "$E1_S" } ] } },
  { "tag": "eu1-vless", "protocol": "vless", "settings": { "vnext": [ { "address": "$EU1_IP", "port": 443, "users": [ { "id": "$E1_U", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "$EU1_SNI", "fingerprint": "chrome", "publicKey": "$E1_PT", "shortId": "$E1_ST", "spiderX": "/" } } },
  { "tag": "eu1-xhttp", "protocol": "vless", "settings": { "vnext": [ { "address": "$EU1_IP", "port": 4433, "users": [ { "id": "$E1_U", "encryption": "none" } ] } ] }, "streamSettings": { "network": "xhttp", "security": "reality", "xhttpSettings": { "path": "/$E1_XP", "mode": "auto" }, "realitySettings": { "serverName": "$EU1_SNI", "fingerprint": "chrome", "publicKey": "$E1_PX", "shortId": "$E1_SX", "spiderX": "/" } } }
]
EOF
    jq --slurpfile nodes /tmp/eu_nodes.json '.outbounds = $nodes[0] + .outbounds | .observatory.subjectSelector = ["eu1-ss", "eu1-vless", "eu1-xhttp"] | .routing.balancers[0].selector = ["eu1-ss", "eu1-vless", "eu1-xhttp"]' /tmp/ru_base.json > /tmp/xray_ru.json
    
    /usr/local/bin/xray run -test -config /tmp/xray_ru.json >/dev/null 2>&1 || { echo "❌ Ошибка конфига RU!"; read -p "Нажми Enter..."; return; }
    mv /tmp/xray_ru.json /usr/local/etc/xray/config.json
    systemctl restart xray
    
    install_ssantifilter

    echo "🎉 ВСЯ ИНФРАСТРУКТУРА УСПЕШНО РАЗВЕРНУТА!"
    L_RU="vless://$CLIENT_UUID@$DOMAIN:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$DOMAIN#Admin"
    echo -e "\n🔗 ТВОЯ ОСНОВНАЯ ССЫЛКА МОСТА:"
    echo "$L_RU"
    qrencode -t UTF8 "$L_RU"
}

add_eu_node() {
    if [ ! -f /usr/local/etc/xray/config.json ]; then echo "❌ Xray конфиг не найден."; return; fi
    read -p "Укажи тег для добавления (например: eu2): " TAG
    
    # 1. Проверка дубля по ТЕГУ
    if grep -q "\"${TAG}-vless\"" /usr/local/etc/xray/config.json 2>/dev/null; then
        echo "⚠️ ВНИМАНИЕ: Нода с тегом $TAG уже существует в мосте!"
        read -p "Переустановить её (очистить ключи и перезаписать)? (y/n): " REINSTALL
        if [ "$REINSTALL" != "y" ]; then return; fi
    fi

    read -p "Введи IP-адрес EU-сервера: " EU_IP
    
    # 2. Проверка дубля по IP
    if jq -r '.outbounds[]? | .settings.vnext[0].address // .settings.servers[0].address' /usr/local/etc/xray/config.json 2>/dev/null | grep -q "^$EU_IP$"; then
        echo "⚠️ ВНИМАНИЕ: Сервер с таким IP ($EU_IP) уже подключен к мосту!"
        read -p "Точно продолжить (например, для переустановки)? (y/n): " FORCE_IP
        if [ "$FORCE_IP" != "y" ]; then return; fi
    fi

    read -p "Сайт маскировки (SNI) [swdist.apple.com]: " EU_SNI; EU_SNI=${EU_SNI:-swdist.apple.com}; EU_SNI=$(echo "$EU_SNI" | tr -d ' \r\n')
    read -s -p "Пароль от root (ввод скрыт): " EU_PASS; echo ""
    
    # 3. Удаляем старый отпечаток SSH (защита от ошибки MITM при переустановке сервера)
    ssh-keygen -R "$EU_IP" >/dev/null 2>&1
    
    RAW=$(setup_eu_node "$EU_IP" "$EU_SNI" "$EU_PASS" "$TAG")
    U=$(echo "$RAW" | awk -F'|' '{print $2}' | tr -d ' \r\n'); S=$(echo "$RAW" | awk -F'|' '{print $3}' | tr -d ' \r\n')
    PT=$(echo "$RAW" | awk -F'|' '{print $4}' | tr -d ' \r\n'); ST=$(echo "$RAW" | awk -F'|' '{print $5}' | tr -d ' \r\n')
    PX=$(echo "$RAW" | awk -F'|' '{print $6}' | tr -d ' \r\n'); SX=$(echo "$RAW" | awk -F'|' '{print $7}' | tr -d ' \r\n')
    XP=$(echo "$RAW" | awk -F'|' '{print $8}' | tr -d ' \r\n')
    
    echo "⏳ Вживляю настройки $TAG в конфиг RU-моста..."
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.backup_$(date +%s).json
    
    cat <<EOF > /tmp/new_outbounds.json
[
  { "tag": "${TAG}-ss", "protocol": "shadowsocks", "settings": { "servers": [ { "address": "$EU_IP", "port": 5000, "method": "2022-blake3-aes-128-gcm", "password": "$S" } ] } },
  { "tag": "${TAG}-vless", "protocol": "vless", "settings": { "vnext": [ { "address": "$EU_IP", "port": 443, "users": [ { "id": "$U", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "$EU_SNI", "fingerprint": "chrome", "publicKey": "$PT", "shortId": "$ST", "spiderX": "/" } } },
  { "tag": "${TAG}-xhttp", "protocol": "vless", "settings": { "vnext": [ { "address": "$EU_IP", "port": 4433, "users": [ { "id": "$U", "encryption": "none" } ] } ] }, "streamSettings": { "network": "xhttp", "security": "reality", "xhttpSettings": { "path": "/$XP", "mode": "auto" }, "realitySettings": { "serverName": "$EU_SNI", "fingerprint": "chrome", "publicKey": "$PX", "shortId": "$SX", "spiderX": "/" } } }
]
EOF
    # Аккуратно удаляем старые записи этого тега (важно при переустановке), а затем вшиваем новые
    jq --arg t1 "${TAG}-ss" --arg t2 "${TAG}-vless" --arg t3 "${TAG}-xhttp" 'del(.outbounds[]? | select(.tag == $t1 or .tag == $t2 or .tag == $t3))' /usr/local/etc/xray/config.json > /tmp/cfg_1.json
    jq --slurpfile newObs /tmp/new_outbounds.json '.outbounds = $newObs[0] + .outbounds' /tmp/cfg_1.json > /tmp/cfg_2.json
    jq --arg t1 "${TAG}-ss" --arg t2 "${TAG}-vless" --arg t3 "${TAG}-xhttp" '.observatory.subjectSelector = (.observatory.subjectSelector + [$t1, $t2, $t3] | unique) | .routing.balancers[0].selector = (.routing.balancers[0].selector + [$t1, $t2, $t3] | unique)' /tmp/cfg_2.json > /tmp/cfg_final.json
        
    /usr/local/bin/xray run -test -config /tmp/cfg_final.json >/dev/null 2>&1 || { echo "❌ Ошибка интеграции конфига!"; return; }
    mv /tmp/cfg_final.json /usr/local/etc/xray/config.json
    systemctl restart xray
    echo "✅ Готово! RU-мост теперь автоматически распределяет трафик и на $TAG."
}

remove_eu_node() {
    if [ ! -f /usr/local/etc/xray/config.json ]; then echo "❌ Xray конфиг не найден."; return; fi
    read -p "Укажи базовый тег для удаления (например: eu2): " TAG
    echo "⏳ Удаляю ноду $TAG из конфига RU-моста..."
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.backup_$(date +%s).json
    
    jq --arg t1 "${TAG}-ss" --arg t2 "${TAG}-vless" --arg t3 "${TAG}-xhttp" '
      del(.outbounds[]? | select(.tag == $t1 or .tag == $t2 or .tag == $t3)) |
      .observatory.subjectSelector |= map(select(. != $t1 and . != $t2 and . != $t3)) |
      .routing.balancers[0].selector |= map(select(. != $t1 and . != $t2 and . != $t3))
    ' /usr/local/etc/xray/config.json > /tmp/cfg_clean.json
    
    /usr/local/bin/xray run -test -config /tmp/cfg_clean.json >/dev/null 2>&1 || { echo "❌ Ошибка при удалении ноды! JSON сломан."; return; }
    mv /tmp/cfg_clean.json /usr/local/etc/xray/config.json
    systemctl restart xray
    echo "✅ Готово! Настройки $TAG успешно вырезаны из моста."
}

manage_warp_routing() {
    if [ ! -f /usr/local/etc/xray/config.json ]; then echo "❌ Xray конфиг не найден!"; return; fi

    local IPS=$(jq -r '.outbounds[]? | select(.tag | test("-vless$")) | .settings.vnext[0].address' /usr/local/etc/xray/config.json 2>/dev/null | sort -u)
    if [ -z "$IPS" ]; then
        echo "❌ Нет подключенных удаленных EU-серверов."
        return
    fi

    local FIRST_IP=$(echo "$IPS" | head -n 1)
    echo "⏳ Получаю текущие правила WARP с первой ноды ($FIRST_IP)..."
    
    local CURRENT_DOMAINS=$(ssh -o StrictHostKeyChecking=no root@$FIRST_IP "jq -r '.routing.rules[]? | select(.outboundTag==\"warp\") | .domain[]?' /usr/local/etc/xray/config.json 2>/dev/null" < /dev/null | paste -sd, - | sed 's/,/, /g')

    echo "---------------------------------------------------------"
    echo "Текущие домены, идущие через WARP:"
    echo "[ ${CURRENT_DOMAINS:-Нет данных} ]"
    echo "---------------------------------------------------------"
    echo "Форматы ввода:"
    echo "👉 geosite:имя  (например: geosite:google, geosite:instagram)"
    echo "👉 domain:имя   (например: domain:chatgpt.com, domain:2ip.ru)"
    echo "👉 full:имя     (например: full:api.openai.com)"
    echo "---------------------------------------------------------"
    echo "Введите НОВЫЙ список доменов через запятую (или оставь пустым для отмены):"
    read -p "Новый список: " NEW_DOMAINS

    if [ -z "$NEW_DOMAINS" ]; then echo "Отмена."; return; fi

    local JSON_ARRAY=$(echo "$NEW_DOMAINS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$' | jq -R . | jq -s -c .)
    
    if [ -z "$JSON_ARRAY" ] || [ "$JSON_ARRAY" == "[]" ]; then
        echo "❌ Ошибка: получился пустой список или неверный формат."
        return
    fi

    echo "📦 Сформирован новый список: $JSON_ARRAY"

    local B64_ARRAY=$(echo -n "$JSON_ARRAY" | base64 -w 0)

    for IP in $IPS; do
        echo "⏳ Отправка и проверка конфига на $IP..."
        ssh -o StrictHostKeyChecking=no root@$IP "bash -s" << REMOTE_EOF
            NEW_DOMS=\$(echo "$B64_ARRAY" | base64 -d)
            jq --argjson doms "\$NEW_DOMS" '
              .routing.rules |= map(if .outboundTag == "warp" then .domain = \$doms else . end)
            ' /usr/local/etc/xray/config.json > /tmp/xr_warp.json
            
            if /usr/local/bin/xray run -test -config /tmp/xr_warp.json >/dev/null 2>&1; then
                mv /tmp/xr_warp.json /usr/local/etc/xray/config.json
                systemctl restart xray
                echo "   ✅ Успешно обновлено ($IP)"
            else
                echo "   ❌ КРИТИЧЕСКАЯ ОШИБКА: Новый конфиг невалиден! Откат изменений. ($IP)"
                rm -f /tmp/xr_warp.json
            fi
REMOTE_EOF
    done
    echo "🎉 Обновление маршрутов на всех нодах завершено!"
}

change_sni() {
    if [ ! -f /usr/local/etc/xray/config.json ]; then echo "❌ Xray конфиг не найден."; return; fi
    
    local TAGS=$(jq -r '.outbounds[]? | select(.protocol=="vless" and .streamSettings.security=="reality") | .tag' /usr/local/etc/xray/config.json)
    if [ -z "$TAGS" ]; then echo "❌ Нет подключенных EU-серверов с XTLS-Reality."; return; fi
    
    echo "Доступные ноды (теги):"
    echo "$TAGS" | sed 's/-vless//g; s/-xhttp//g' | sort -u
    echo "---------------------------------------------------------"
    read -p "Введи тег ноды для смены SNI (например, eu1): " TARGET_TAG
    
    local EU_IP=$(jq -r --arg t "${TARGET_TAG}-vless" '.outbounds[]? | select(.tag==$t) | .settings.vnext[0].address' /usr/local/etc/xray/config.json)
    if [ -z "$EU_IP" ] || [ "$EU_IP" == "null" ]; then echo "❌ Нода с тегом $TARGET_TAG не найдена."; return; fi
    
    local OLD_SNI=$(jq -r --arg t "${TARGET_TAG}-vless" '.outbounds[]? | select(.tag==$t) | .streamSettings.realitySettings.serverName' /usr/local/etc/xray/config.json)
    
    echo "IP ноды: $EU_IP | Текущий SNI: $OLD_SNI"
    read -p "Введи НОВЫЙ SNI (например, www.microsoft.com): " NEW_SNI
    if [ -z "$NEW_SNI" ]; then echo "Отмена."; return; fi
    
    echo "⏳ Обновляю конфиг на RU-мосте..."
    jq --arg t1 "${TARGET_TAG}-vless" --arg t2 "${TARGET_TAG}-xhttp" --arg sni "$NEW_SNI" '
        .outbounds |= map(
            if .tag == $t1 or .tag == $t2 then
                .streamSettings.realitySettings.serverName = $sni
            else . end
        )
    ' /usr/local/etc/xray/config.json > /tmp/xray_ru_sni.json
    
    if ! /usr/local/bin/xray run -test -config /tmp/xray_ru_sni.json >/dev/null 2>&1; then
        echo "❌ Ошибка в новом конфиге RU. Отмена."; rm -f /tmp/xray_ru_sni.json; return
    fi
    
    echo "⏳ Обновляю конфиг на удаленной EU-ноде ($EU_IP)..."
    ssh -o StrictHostKeyChecking=no root@$EU_IP "bash -s" << REMOTE_EOF
        jq --arg sni "$NEW_SNI" '
            .inbounds |= map(
                if .streamSettings.security == "reality" then
                    .streamSettings.realitySettings.dest = (\$sni + ":443") |
                    .streamSettings.realitySettings.serverNames = [\$sni]
                else . end
            )
        ' /usr/local/etc/xray/config.json > /tmp/xray_eu_sni.json
        
        if /usr/local/bin/xray run -test -config /tmp/xray_eu_sni.json >/dev/null 2>&1; then
            mv /tmp/xray_eu_sni.json /usr/local/etc/xray/config.json
            systemctl restart xray
            echo "   ✅ EU-нода обновлена!"
        else
            echo "   ❌ Ошибка в конфиге EU-ноды. Отмена."
            rm -f /tmp/xray_eu_sni.json
            exit 1
        fi
REMOTE_EOF
    
    if [ $? -eq 0 ]; then
        mv /tmp/xray_ru_sni.json /usr/local/etc/xray/config.json
        systemctl restart xray
        echo "✅ SNI успешно изменен на $NEW_SNI для ноды $TARGET_TAG!"
    else
        echo "❌ Обновление прервано из-за ошибки на EU-ноде."
        rm -f /tmp/xray_ru_sni.json
    fi
}

manage_infrastructure() {
    while true; do
        clear
        echo "========================================================="
        echo "🌍 УПРАВЛЕНИЕ ИНФРАСТРУКТУРОЙ И УЗЛАМИ"
        echo "========================================================="
        
        echo "---🚀 РАЗВЕРТЫВАНИЕ И УДАЛЕНИЕ ---"
        echo "1) 🆕 Развернуть новый мост (RU + EU)"
        echo "2) 🧹 ПОЛНАЯ ОЧИСТКА СЕРВЕРА (Удалить всё)"
        
        echo "---🌐 УПРАВЛЕНИЕ УЗЛАМИ (EU) ---"
        echo "3) ➕ Добавить EU-сервер в мост"
        echo "4) ➖ Удалить EU-сервер из моста"
        
        echo "---⚙️ НАСТРОЙКИ СЕТИ ---"
        echo "5) 🌍 Маршрутизация WARP (обход блокировок на EU)"
        echo "6) 🎭 Смена SNI (сайт маскировки)"
        
        echo "---🔧 ДИАГНОСТИКА ---"
        echo "7) ⚡ Speedtest: Замер скорости (RU <-> EU)"
        echo "8) 🔄 Обновление Xray и Geo-баз"
        
        echo "0) ↩️ Назад в главное меню"
        echo "========================================================="
        read -p "Выбор: " INFRA_ACT
        
        case $INFRA_ACT in
            1) deploy_new_bridge; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            2) full_cleanup ;;
            3) add_eu_node; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            4) remove_eu_node; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            5) manage_warp_routing; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            6) change_sni; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            7) speedtest_bridge ;; # Там пауза уже встроена
            8) update_core_and_geo; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
            0) return ;;
            *) echo "❌ Неверный выбор!" ; sleep 1 ;;
        esac
    done
}

full_cleanup() {
    echo -e "\n🧹 ВЫБРАНА ПОЛНАЯ ОЧИСТКА СЕРВЕРА"
    echo "⚠️  ВНИМАНИЕ! Это действие необратимо!"
    echo "Будут удалены: Xray, Nginx, Docker (панель), все сертификаты SSL и ключи."
    echo "Сервер вернется в почти исходное состояние."
    echo "---------------------------------------------------------"
    
    # Первая проверка
    read -p "❓ Вы уверены, что хотите продолжить? (y/n): " CONFIRM_1
    if [ "$CONFIRM_1" != "y" ]; then 
        echo "❌ Отмена действия."
        return 
    fi

    # Вторая проверка (красная тревога)
    echo -e "\n🔥 ПОСЛЕДНЕЕ ПРЕДУПРЕЖДЕНИЕ 🔥"
    echo "Все данные пользователей и настройки будут УНИЧТОЖЕНЫ."
    read -p "❓ Вы ТОЧНО уверены? (введите 'yes' для удаления): " CONFIRM_2
    
    if [ "$CONFIRM_2" != "yes" ]; then 
        echo "❌ Отмена. Нужно ввести 'yes' целиком."
        return 
    fi

    echo "💣 НАЧИНАЮ УДАЛЕНИЕ..."
    
    # Остановка служб
    systemctl stop xray nginx 2>/dev/null
    systemctl disable xray 2>/dev/null
    
    # Удаление Docker контейнера (если есть)
    if command -v docker &> /dev/null; then 
        docker rm -f ssantifilter 2>/dev/null
    fi

    # Удаление файлов
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /var/log/xray /var/lib/xray /data/ssantifilter
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/nginx/sites-available/default
    rm -f /usr/local/bin/vpn-bot
    rm -rf /usr/src/vpn-bot
	
    # Перезагрузка демонов
    systemctl daemon-reload 
    systemctl restart nginx 2>/dev/null
    
    echo "✅ Система полностью очищена. Можно накатывать мост заново (Пункт 4)."
    # Мы не делаем exit 0, чтобы вы остались в меню и могли сразу выбрать пункт установки
    read -p "Нажми Enter..."
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (COMPACT VERSION)
# ==============================================================================
while true; do
    clear
    echo "#########################################################"
    echo "🚀 KVN BRIDGE MASTER v4.0 | Admin Panel"
    echo "#########################################################"
    show_system_status
    
    echo "🔹 ОСНОВНОЕ"
    echo "1) 🌍 ИНФРАСТРУКТУРА (Установка, Ноды, Speedtest, Очистка)"
    echo "2) 👥 Менеджер Пользователей"
    echo "3) 📊 Статистика Трафика"
    echo "4) 📜 Логи (Xray, Nginx, Docker)"
    
    echo "🔹 ОБСЛУЖИВАНИЕ И БЕЗОПАСНОСТЬ"
    echo "5) 📦 Бекап (Telegram)"
    echo "6) ♻️  Восстановление из бекапа"
    echo "7) 🛡️ Hardening (SSH, Fail2Ban, SWAP)"
    
    echo "🔹 АВТОМАТИЗАЦИЯ"
    echo "8) 🔔 SSH Алерты"
    echo "9) 🤖 Telegram Бот"
    echo "10)⚙️ Автозапуск меню"
    echo "11)⬆️ Обновление скрипта"
	echo "12)⬆️ Нестабильная версия"
    
    echo "0) 🚪 Выход"
    echo "#########################################################"
    read -p "Выбор: " ACTION
    echo ""

    case $ACTION in
        1) manage_infrastructure ;;
        2) manage_users ;;
        3) show_stats ;;
        4) show_logs ;;
        5) tg_backup ;;
        6) restore_from_backup ;;
        7) harden_system ;;
        8) setup_ssh_notify ;;
        9) setup_tg_bot ;;
        10) toggle_autostart ;;
        11) update_script ;;
		12) update_script_test ;;
        0) echo "👋 До встречи!"; exit 0 ;;
        *) echo "❌ Неверный выбор!" ;;
    esac

    # Если мы вернулись из подменю инфраструктуры, пауза не нужна.
    # Для остальных пунктов делаем паузу, чтобы успеть прочитать вывод.
    if [ "$ACTION" != "1" ]; then
        echo ""
        read -n 1 -s -r -p "Нажми любую клавишу для возврата в меню..."
    fi
done
