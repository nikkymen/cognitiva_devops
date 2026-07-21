#!/bin/bash

# --- КОНФИГУРАЦИЯ ШАР ---
SHARES=(
    "storage:/mnt/user/share /mnt/nas/share"
    "storage:/mnt/user/storage /mnt/nas/storage"
)
MOUNT_OPTIONS="nfs4 defaults,_netdev,noatime,nofail,x-systemd.automount,x-systemd.idle-timeout=300,nfsvers=4.2,timeo=600,retrans=2 0 0"
# ------------------------------

# Установка необходимых пакетов в зависимости от дистрибутива
install_nfs_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "[*] Обнаружен Debian/Ubuntu. Установка nfs-common..."
        apt-get update -qq
        apt-get install -y -qq nfs-common
    elif command -v dnf >/dev/null 2>&1; then
        echo "[*] Обнаружен Fedora/RHEL (dnf). Установка nfs-utils..."
        dnf install -y nfs-utils
    elif command -v yum >/dev/null 2>&1; then
        echo "[*] Обнаружен RHEL/CentOS (yum). Установка nfs-utils..."
        yum install -y nfs-utils
    elif command -v zypper >/dev/null 2>&1; then
        echo "[*] Обнаружен openSUSE/SUSE. Установка nfs-client..."
        zypper --non-interactive install nfs-client
    elif command -v pacman >/dev/null 2>&1; then
        echo "[*] Обнаружен Arch/Manjaro. Установка nfs-utils..."
        pacman -Sy --noconfirm nfs-utils
    elif command -v apk >/dev/null 2>&1; then
        echo "[*] Обнаружен Alpine. Установка nfs-utils..."
        apk add --no-cache nfs-utils
    else
        echo "[!] Не удалось определить пакетный менеджер."
        echo "    Убедитесь, что установлен пакет для NFS:"
        echo "      Debian/Ubuntu: nfs-common"
        echo "      RHEL/CentOS/Fedora: nfs-utils"
        echo "      openSUSE/SUSE: nfs-client"
        echo "      Arch/Manjaro: nfs-utils"
        echo "      Alpine: nfs-utils"
    fi
}

# 1. ЗАЩИТА: Немедленно уводим сам скрипт в безопасную директорию
cd / || exit 1

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: Этот скрипт должен быть запущен с правами root."
  echo "Установка: curl -sSL ... | sudo bash"
  echo "Удаление:  curl -sSL ... | sudo bash -s -- --remove"
  exit 1
fi

# Определяем режим работы
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

        # Ленивое размонтирование, чтобы не зависнуть из-за Stale Handle или открытых терминалов
        echo "[*] Принудительное освобождение точки монтирования $LOCAL..."
        umount -lf "$LOCAL" 2>/dev/null

        if grep -qF "$REMOTE $LOCAL" /etc/fstab; then
            echo "[+] Удаление записи для $LOCAL из /etc/fstab"
            awk -v r="$REMOTE" -v l="$LOCAL" '$1 != r || $2 != l' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
            FSTAB_CHANGED=true
        fi

        if [ -d "$LOCAL" ]; then
            echo "[*] Удаление директории $LOCAL (если она пуста)..."
            rmdir "$LOCAL" 2>/dev/null || echo "[~] Папка $LOCAL не пуста, оставляем как есть."
        fi
    done

# --- РЕЖИМ УСТАНОВКИ / ОБНОВЛЕНИЯ ---
else
    echo "[*] Запущен режим настройки NFS шар..."

    install_nfs_packages

    for SHARE_INFO in "${SHARES[@]}"; do
        read -r REMOTE LOCAL <<< "$SHARE_INFO"

        if [ ! -d "$LOCAL" ]; then
            echo "[+] Создание директории: $LOCAL"
            mkdir -p "$LOCAL"
        fi

        FSTAB_LINE="$REMOTE $LOCAL $MOUNT_OPTIONS"

        if grep -qF "$FSTAB_LINE" /etc/fstab; then
            echo "[~] Конфигурация для $LOCAL уже актуальна."
        else
            if grep -qF "$REMOTE $LOCAL" /etc/fstab; then
                echo "[*] Обновление устаревших опций для $LOCAL"
                awk -v r="$REMOTE" -v l="$LOCAL" '$1 != r || $2 != l' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
            else
                echo "[+] Добавление новой записи для $LOCAL"
            fi

            if [ -n "$(tail -c1 /etc/fstab 2>/dev/null)" ]; then
                echo "" >> /etc/fstab
            fi

            echo "$FSTAB_LINE" >> /etc/fstab
            FSTAB_CHANGED=true
        fi
    done
fi

# --- ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ (С ЗАЩИТОЙ ОТ ЗАВИСАНИЯ) ---
if [ "$FSTAB_CHANGED" = true ]; then
    # Если fstab менялся, принудительно делаем lazy umount для ВСЕХ наших шар.
    # Это разорвет дедлок, если пользователь запустил скрипт, находясь внутри этих папок.
    echo "[*] Сброс активных сессий монтирования (lazy unmount)..."
    for SHARE_INFO in "${SHARES[@]}"; do
        read -r REMOTE LOCAL <<< "$SHARE_INFO"
        umount -lf "$LOCAL" 2>/dev/null
    done

    echo "[*] Применение изменений в systemd..."
    systemctl daemon-reload
    systemctl restart local-fs.target remote-fs.target

    if [ "$MODE" = "remove" ]; then
        echo "[+] Все шары успешно удалены и размонтированы."
    else
        echo "[+] Настройка успешно завершена. Новые параметры активны."
    fi
else
    echo "[~] Изменений в конфигурации системы не потребовалось."
fi
