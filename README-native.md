# Analytics Dashboard — Native Deploy (без Docker)

Полная инструкция по развёртыванию стека **без Docker**.  
Стек: **PostgreSQL 15 · Grafana · Streamlit · Nginx** — всё нативно через systemd.

---

## Почему без Docker?

Если на сервере запрещена двойная виртуализация (вложенные контейнеры внутри VM),
стандартный `deploy.sh` не подойдёт. Этот набор файлов решает задачу нативной установкой.

---

## Файлы в этом пакете

| Файл | Назначение |
|------|-----------|
| `deploy-native.sh` | Первый запуск: ставит всё с нуля |
| `update-native.sh` | Обновление: git pull + перезапуск сервисов |
| `scripts/setup_users-native.sh` | Создание Grafana-аккаунтов сотрудников |
| `nginx-native.conf` | Конфиг Nginx (localhost вместо Docker-хостов) |
| `grafana_config/provisioning/datasources/datasource-native.yml` | Datasource Grafana (localhost:5432) |

---

## Первый запуск на сервере

### 1. Клонировать репозиторий

```bash
git clone https://github.com/Greyswandir-gg/migration_package_v2.git /opt/analytics
cd /opt/analytics
```

### 2. Скопировать нативные файлы поверх

```bash
cp deploy-native.sh /opt/analytics/
cp update-native.sh /opt/analytics/
cp scripts/setup_users-native.sh /opt/analytics/scripts/
cp grafana_config/provisioning/datasources/datasource-native.yml \
   /opt/analytics/grafana_config/provisioning/datasources/datasource.yml
```

### 3. Запустить деплой

```bash
chmod +x /opt/analytics/deploy-native.sh
bash /opt/analytics/deploy-native.sh
```

Опциональные параметры:

```bash
bash deploy-native.sh --port 8081
bash deploy-native.sh --port 80 --domain example.com --admin-pass MyPassword
```

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `--port` | авто (80/8081) | Порт Nginx |
| `--domain` | IP сервера | Домен или IP |
| `--dir` | /opt/analytics | Папка установки |
| `--admin-pass` | admin | Пароль Grafana admin |

Скрипт сам:
- Установит PostgreSQL 15, Grafana, Python 3, Nginx
- Создаст БД и пользователя
- Настроит Grafana provisioning
- Создаст systemd-сервис для Streamlit
- Настроит Nginx и применит SQL-структуру

### 4. Загрузить данные

После запуска открыть **Admin App** и загрузить Excel-файл:

```
http://<IP>:<PORT>/app
```

Логин: `admin` / Пароль: `admin123`  
Использовать **Full Refresh Upload** при первой загрузке.

### 5. Создать пользователей для сотрудников

```bash
bash /opt/analytics/scripts/setup_users-native.sh
```

Опции:
```bash
bash scripts/setup_users-native.sh --pass "MySecret123!" --admin-pass "GrafanaAdmin"
```

---

## Обновление сервера

```bash
bash /opt/analytics/update-native.sh
```

Только перезапустить сервисы без git pull:
```bash
bash /opt/analytics/update-native.sh --restart-only
```

---

## Доступы

| Сервис | URL | Логин | Пароль |
|--------|-----|-------|--------|
| Grafana (admin) | `/grafana/` | admin | задаётся при деплое |
| Admin App | `/app` | admin | admin123 |
| Grafana (сотрудник) | `/grafana/` | фамилия.имя | Welcome2026! |

---

## Полезные команды

### Статус сервисов

```bash
systemctl status postgresql grafana-server analytics-app nginx
```

### Логи

```bash
journalctl -u analytics-app -f        # Streamlit
journalctl -u grafana-server -f       # Grafana
journalctl -u nginx -f                # Nginx
journalctl -u postgresql -f           # PostgreSQL
```

### Перезапуск

```bash
systemctl restart analytics-app       # только Streamlit
systemctl restart grafana-server      # только Grafana
systemctl reload nginx                # только Nginx
```

### Войти в БД

```bash
PGPASSWORD=secretpassword psql -U admin -h 127.0.0.1 -d analytics_db
```

### Сбросить пароль сотрудника в Grafana

```bash
curl -s -u admin:ADMIN_PASS \
  -X PUT http://localhost:3000/grafana/api/admin/users/<USER_ID>/password \
  -H "Content-Type: application/json" \
  -d '{"password":"НовыйПароль123!"}'
```

---

## Что изменено по сравнению с Docker-версией

| Файл оригинала | Что изменено |
|---------------|-------------|
| `deploy.sh` | Переписан: вместо Docker — apt + systemd |
| `update.sh` | Переписан: вместо `docker compose up` — `systemctl restart` |
| `scripts/setup_users.sh` | Убраны `docker exec`, прямые вызовы psql и curl |
| `nginx.conf` | Хосты `grafana:3000`, `web_app:8501` → `127.0.0.1` |
| `grafana_config/provisioning/datasources/datasource.yml` | `url: db:5432` → `url: localhost:5432` |
