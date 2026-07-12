#!/bin/bash

# --- КОНФИГУРАЦИЯ ШАР ---
# Ты можешь добавлять, менять или удалять строки. Скрипт сам синхронизирует состояние.
SHARES=(
    "storage:/mnt/user/share /share"
    "storage:/mnt/user/storage /storage"
)

# Опции для самого монтирования (опции automount перенесены в отдельную секцию ниже)
MOUNT_OPTIONS="defaults,_netdev,noatime,nofail,timeo=600,retrans=2"
IDLE_TIMEOUT=300 # Время простоя в секундах (x-systemd.idle-timeout)
# ------------------------------

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: Этот скрипт должен быть запущен с правами root."
  echo "Используйте: curl -sSL ... | sudo bash"
  exit 1
fi

echo "[*] Начало синхронизации NFS шаров через systemd..."

# Массив для отслеживания обрабатываемых в данный момент юнитов
ACTIVE_UNITS=()

for SHARE_INFO in "${SHARES[@]}"; do
    read -r REMOTE LOCAL <<< "$SHARE_INFO"

    # 1. Создаем локальную директорию, если её нет
    if [ ! -d "$LOCAL" ]; then
        echo "[+] Создание директории: $LOCAL"
        mkdir -p "$LOCAL"
    fi

    # 2. Переводим путь в имя юнита systemd (например, /share -> share)
    UNIT_NAME=$(systemd-escape --path "$LOCAL")
    ACTIVE_UNITS+=("$UNIT_NAME")

    MOUNT_FILE="/etc/systemd/system/${UNIT_NAME}.mount"
    AUTOMOUNT_FILE="/etc/systemd/system/${UNIT_NAME}.automount"
    
    UNIT_CHANGED=false

    # Шаблон для .mount файла
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

    # Шаблон для .automount файла
    AUTOMOUNT_CONTENT="[Unit]
Description=Automount for NFS $LOCAL (Managed by GitOps script)

[Automount]
Where=$LOCAL
TimeoutIdleSec=$IDLE_TIMEOUT

[Install]
WantedBy=multi-user.target"

    # 3. Проверяем/создаем .mount юнит
    if [ ! -f "$MOUNT_FILE" ] || [ "$MOUNT_CONTENT" != "$(cat "$MOUNT_FILE")" ]; then
        echo "[+] Обновление конфигурации монтирования: $MOUNT_FILE"
        echo "$MOUNT_CONTENT" > "$MOUNT_FILE"
        UNIT_CHANGED=true
    fi

    # 4. Проверяем/создаем .automount юнит
    if [ ! -f "$AUTOMOUNT_FILE" ] || [ "$AUTOMOUNT_CONTENT" != "$(cat "$AUTOMOUNT_FILE")" ]; then
        echo "[+] Обновление конфигурации автомонтирования: $AUTOMOUNT_FILE"
        echo "$AUTOMOUNT_CONTENT" > "$AUTOMOUNT_FILE"
        UNIT_CHANGED=true
    fi

    # 5. Активируем службы, если были изменения или они не запущены
    if [ "$UNIT_CHANGED" = true ] || ! systemctl is-enabled "${UNIT_NAME}.automount" &>/dev/null; then
        echo "[*] Перезапуск службы автомонтирования для $LOCAL..."
        systemctl daemon-reload
        systemctl enable "${UNIT_NAME}.automount" &>/dev/null
        systemctl restart "${UNIT_NAME}.automount"
    else
        echo "[~] Шара $LOCAL уже в актуальном состоянии."
    fi
done

# --- БЛОК ОЧИСТКИ УСТАРЕВШИХ ШАР ---
# Скрипт просматривает систему на наличие старых юнитов, помеченных им же,
# и если их больше нет в массиве SHARES на GitHub — полностью удаляет их из ОС.
echo "[*] Проверка на наличие удаленных шар..."
for f in /etc/systemd/system/*.automount; do
    [ -e "$f" ] || continue
    if grep -q "Managed by GitOps script" "$f"; then
        FILE_NAME=$(basename "$f" .automount)
        
        # Если найденного файла нет в списке активных — удаляем его
        if [[ ! " ${ACTIVE_UNITS[@]} " =~ " ${FILE_NAME} " ]]; then
            echo "[-] Найдена устаревшая конфигурация: $FILE_NAME. Удаление..."
            
            # Получаем точку монтирования из имени юнита для корректного размонтирования
            MOUNT_POINT=$(systemd-escape --path --unescape "$FILE_NAME")
            
            systemctl disable --now "${FILE_NAME}.automount" &>/dev/null
            umount -lf "$MOUNT_POINT" &>/dev/null
            
            rm -f "/etc/systemd/system/${FILE_NAME}.automount"
            rm -f "/etc/systemd/system/${FILE_NAME}.mount"
            
            # Пытаемся удалить пустую директорию (если в ней ничего нет)
            rmdir "$MOUNT_POINT" 2>/dev/null 
            
            systemctl daemon-reload
        fi
    fi
done

echo "[+] Синхронизация успешно завершена!"
