#!/bin/bash

# --- КОНФИГУРАЦИЯ ШАР ---
SHARES=(
    "storage:/mnt/user/share /share"
    "storage:/mnt/user/storage /storage"
)

MOUNT_OPTIONS="defaults,_netdev,noatime,nofail,timeo=100,retrans=1"
IDLE_TIMEOUT=300 
# ------------------------------

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: Этот скрипт должен быть запущен с правами root."
  echo "Используйте: curl -sSL ... | sudo bash"
  exit 1
fi

# === РЕЖИМ ОТКЛЮЧЕНИЯ (ВЫЗОВ С АРГУМЕНТОМ disable) ===
if [[ "$1" == "disable" || "$1" == "--disable" ]]; then
    echo "[*] Запущен режим отключения NFS шаров..."
    
    for SHARE_INFO in "${SHARES[@]}"; do
        read -r REMOTE LOCAL <<< "$SHARE_INFO"
        UNIT_NAME=$(systemd-escape --path "$LOCAL")
        
        echo "[-] Отключение и удаление автомонтирования для $LOCAL..."
        
        # Останавливаем и деактивируем службы
        systemctl disable --now "${UNIT_NAME}.automount" &>/dev/null
        systemctl disable --now "${UNIT_NAME}.mount" &>/dev/null
        
        # «Лениво» размонтируем папку, если она была смонтирована
        umount -lf "$LOCAL" &>/dev/null
        
        # Удаляем конфигурационные файлы юнитов
        rm -f "/etc/systemd/system/${UNIT_NAME}.automount"
        rm -f "/etc/systemd/system/${UNIT_NAME}.mount"
        
        # Удаляем пустую директорию точки монтирования
        rmdir "$LOCAL" 2>/dev/null
    done
    
    # Перезапускаем конфигурацию systemd, чтобы применить удаление
    systemctl daemon-reload
    echo "[+] Все настроенные шары успешно отключены и удалены с этого хоста!"
    exit 0
fi


# === РЕЖИМ УСТАНОВКИ / СИНХРОНИЗАЦИИ (ОБЫЧНЫЙ ВЫЗОВ) ===
echo "[*] Начало синхронизации NFS шаров через systemd..."
ACTIVE_UNITS=()

for SHARE_INFO in "${SHARES[@]}"; do
    read -r REMOTE LOCAL <<< "$SHARE_INFO"
    UNIT_NAME=$(systemd-escape --path "$LOCAL")
    ACTIVE_UNITS+=("$UNIT_NAME")

    if [ ! -d "$LOCAL" ]; then
        echo "[+] Создание директории: $LOCAL"
        mkdir -p "$LOCAL"
    fi

    MOUNT_FILE="/etc/systemd/system/${UNIT_NAME}.mount"
    AUTOMOUNT_FILE="/etc/systemd/system/${UNIT_NAME}.automount"
    UNIT_CHANGED=false

    MOUNT_CONTENT="[Unit]
Description=NFS Mount for $LOCAL (Managed by GitOps script)
After=network-online.target
Wants=network-online.target

[Mount]
What=$REMOTE
Where=$LOCAL
Type=nfs4
Options=$MOUNT_OPTIONS

[Install]
WantedBy=multi-user.target"

    AUTOMOUNT_CONTENT="[Unit]
Description=Automount for NFS $LOCAL (Managed by GitOps script)

[Automount]
Where=$LOCAL
TimeoutIdleSec=$IDLE_TIMEOUT

[Install]
WantedBy=multi-user.target"

    if [ ! -f "$MOUNT_FILE" ] || [ "$MOUNT_CONTENT" != "$(cat "$MOUNT_FILE")" ]; then
        echo "[+] Обновление конфигурации монтирования: $MOUNT_FILE"
        echo "$MOUNT_CONTENT" > "$MOUNT_FILE"
        UNIT_CHANGED=true
    fi

    if [ ! -f "$AUTOMOUNT_FILE" ] || [ "$AUTOMOUNT_CONTENT" != "$(cat "$AUTOMOUNT_FILE")" ]; then
        echo "[+] Обновление конфигурации автомонтирования: $AUTOMOUNT_FILE"
        echo "$AUTOMOUNT_CONTENT" > "$AUTOMOUNT_FILE"
        UNIT_CHANGED=true
    fi

    if [ "$UNIT_CHANGED" = true ] || ! systemctl is-enabled "${UNIT_NAME}.automount" &>/dev/null; then
        echo "[*] Перезапуск службы автомонтирования для $LOCAL..."
        systemctl daemon-reload
        systemctl enable "${UNIT_NAME}.automount" &>/dev/null
        systemctl restart "${UNIT_NAME}.automount"
    else
        echo "[~] Шара $LOCAL уже в актуальном состоянии."
    fi
done

# Блок очистки устаревших конфигураций
echo "[*] Проверка на наличие удаленных в репозитории шар..."
for f in /etc/systemd/system/*.automount; do
    [ -e "$f" ] || continue
    if grep -q "Managed by GitOps script" "$f"; then
        FILE_NAME=$(basename "$f" .automount)
        
        if [[ ! " ${ACTIVE_UNITS[@]} " =~ " ${FILE_NAME} " ]]; then
            echo "[-] Удаление устаревшей конфигурации: $FILE_NAME..."
            MOUNT_POINT=$(systemd-escape --path --unescape "$FILE_NAME")
            
            systemctl disable --now "${FILE_NAME}.automount" &>/dev/null
            umount -lf "$MOUNT_POINT" &>/dev/null
            
            rm -f "/etc/systemd/system/${FILE_NAME}.automount"
            rm -f "/etc/systemd/system/${FILE_NAME}.mount"
            rmdir "$MOUNT_POINT" 2>/dev/null 
            
            systemctl daemon-reload
        fi
    fi
done

echo "[+] Синхронизация успешно завершена!"
