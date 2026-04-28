# Puppet Mail Server

Быстрое развёртывание почтового сервера (Postfix + Dovecot) на Ubuntu 24.04 через Puppet.

Протестировано на Ubuntu 24.04.4 LTS ARM64 (Parallels VM на macOS). Время деплоя — ~28 секунд.

## Что ставится

| Компонент | Роль |
|-----------|------|
| Postfix   | SMTP — отправка и приём писем (порты 25, 587) |
| Dovecot   | IMAP/POP3 — чтение писем клиентами (порты 143, 993, 110, 995) |
| mailutils | Утилиты командной строки для почты |
| ufw       | Фаервол — открывает порты 22, 25, 587, 143, 993, 110, 995 |

## Быстрый старт

### Вариант 1: Parallels VM (macOS → Ubuntu)

```bash
# 1. Установить Puppet в VM
ssh user@<VM_IP> "sudo apt update && sudo apt install -y puppet"

# 2. Скопировать манифест
scp mailserver.pp user@<VM_IP>:/tmp/

# 3. Применить
ssh user@<VM_IP> "sudo puppet apply /tmp/mailserver.pp"
```

### Вариант 2: Напрямую на сервере

```bash
sudo apt update && sudo apt install -y puppet
sudo puppet apply mailserver.pp
```

## Проверка

```bash
# Отправка тестового письма
echo "Hello from mailserver" | sendmail user@localhost

# Проверка доставки (подождать 5 сек)
ls ~/Maildir/new/
cat ~/Maildir/new/*

# Статус сервисов
systemctl status postfix dovecot

# Открытые порты
ss -tlnp | grep -E "25|587|143|993|110|995"

# Фаервол
sudo ufw status
```

## Настройка

Перед запуском отредактируй в `mailserver.pp`:

```puppet
$domain = 'example.com'  # → свой домен
```

## Порты

| Порт | Протокол | Назначение |
|------|----------|------------|
| 22   | TCP      | SSH |
| 25   | TCP      | SMTP |
| 587  | TCP      | Submission (TLS) |
| 143  | TCP      | IMAP |
| 993  | TCP      | IMAPS |
| 110  | TCP      | POP3 |
| 995  | TCP      | POP3S |

## Структура файлов

```
PuppetCode/
├── mailserver.pp   — основной манифест (один файл, всё включено)
└── README.md       — документация
```

## Что делает манифест

1. Устанавливает пакеты (postfix, dovecot, mailutils, ufw)
2. Генерирует self-signed SSL сертификат
3. Настраивает Postfix (main.cf) — домен, TLS, SASL через Dovecot, Maildir
4. Настраивает Dovecot — IMAP/POP3, SSL, SASL сокет для Postfix
5. Запускает и включает сервисы
6. Открывает порты в UFW (включая SSH)
