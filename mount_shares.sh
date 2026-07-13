#!/bin/bash

# --- КОНФИГУРАЦИЯ ШАР ---
SHARES=(
    "storage:/mnt/user/share /share"
    "storage:/mnt/user/storage /storage"
)
MOUNT_OPTIONS="nfs4 defaults,_netdev,noatime,nofail,x-systemd.automount,x-systemd.idle-timeout=300,timeo=600,retrans=2 0 0"
# ------------------------------

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: Этот скрипт должен быть запущен с правами root."
  echo "Установка: curl -sSL ... | sudo bash"
  echo "Удаление:  curl -sSL ... | sudo bash -s -- --remove"
  exit 1
fi

# Определяем режим работы (по умолчанию - установка)
MODE="install"
if [[ "$1" == "--remove" || "$1" == "remove" ]]; then
    MODE="remove"
fi

FSTAB_CHANGED=false

# --- РЕЖИМ УДАЛЕНИЯ ---
if [ "$MODE" = "remove" ]; then
    echo "[*] Запущен режим удаления настроенных NFS шаров..."
    
    for SHARE_INFO in "${SHARES[@]}"; do
        read -r REMOTE LOCAL <<< "$SHARE_INFO"
        
        # 1. Ленивое размонтирование (чтобы не зависнуть из-за Stale Handle)
        if mountpoint -q "$LOCAL"; then
            echo "[*] Размонтирование $LOCAL..."
            umount -lf "$LOCAL"
        fi
        
        # 2. Безопасное удаление строки из /etc/fstab через awk
        # Проверяем, есть ли запись в файле
        if grep -qF "$REMOTE $LOCAL" /etc/fstab; then
            echo "[+] Удаление записи для $LOCAL из /etc/fstab"
            # Оставляем только те строки, где $1 НЕ равен REMOTE или $2 НЕ равен LOCAL
            awk -v r="$REMOTE" -v l="$LOCAL" '$1 != r || $2 != l' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
            FSTAB_CHANGED=true
        fi
        
        # 3. Удаление папки, только если она пустая
        if [ -d "$LOCAL" ]; then
            echo "[*] Удаление директории $LOCAL (если она пуста)..."
            rmdir "$LOCAL" 2>/dev/null || echo "[~] Папка $LOCAL не пуста или занята, оставляем как есть."
        fi
    done

# --- РЕЖИМ УСТАНОВКИ / ОБНОВЛЕНИЯ ---
else
    echo "[*] Запущен режим настройки NFS шаров..."
    
    for SHARE_INFO in "${SHARES[@]}"; do
        read -r REMOTE LOCAL <<< "$SHARE_INFO"
        
        # 1. Создаем локальную директорию, если её нет
        if [ ! -d "$LOCAL" ]; then
            echo "[+] Создание директории: $LOCAL"
            mkdir -p "$LOCAL"
        fi
        
        FSTAB_LINE="$REMOTE $LOCAL $MOUNT_OPTIONS"
        
        # Проверяем, существует ли уже ТОЧНО ТАКАЯ ЖЕ строка
        if grep -qF "$FSTAB_LINE" /etc/fstab; then
            echo "[~] Конфигурация для $LOCAL уже актуальна."
        else
            # Если запись с такими путями была, но с другими опциями — удаляем старую версию
            if grep -qF "$REMOTE $LOCAL" /etc/fstab; then
                echo "[*] Обновление устаревших опций для $LOCAL"
                awk -v r="$REMOTE" -v l="$LOCAL" '$1 != r || $2 != l' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
            else
                echo "[+] Добавление новой записи для $LOCAL"
            fi
            
            # Страховка от отсутствия переноса строки в конце fstab
            if [ -n "$(tail -c1 /etc/fstab 2>/dev/null)" ]; then
                echo "" >> /etc/fstab
            fi
            
            # Добавляем новую чистую строку
            echo "$FSTAB_LINE" >> /etc/fstab
            FSTAB_CHANGED=true
        fi
    done
fi

# --- ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ ---
if [ "$FSTAB_CHANGED" = true ]; then
    echo "[*] Применение изменений в systemd..."
    systemctl daemon-reload
    if [ "$MODE" = "remove" ]; then
        systemctl restart local-fs.target remote-fs.target
        echo "[+] Все шары успешно удалены и размонтированы."
    else
        systemctl restart local-fs.target remote-fs.target
        echo "[+] Настройка успешно завершена. Новые параметры активны."
    fi
else
    echo "[~] Изменений в конфигурации системы не потребовалось."
fi
