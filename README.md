# Analytics Dashboard

Система аналитики рабочего времени на основе Excel-данных.  
Стек: **PostgreSQL · Grafana · Streamlit · Nginx · Docker**

---

## Содержание

- [Структура проекта](#структура-проекта)
- [Первый запуск на сервере](#первый-запуск-на-сервере)
- [Обновление сервера](#обновление-сервера)
- [Автодеплой через GitHub Actions](#автодеплой-через-github-actions)
- [Работа с данными](#работа-с-данными)
- [Полезные команды](#полезные-команды)

---

## Структура проекта

```
├── app/                        # Streamlit-приложение (загрузка Excel)
├── grafana_config/             # Дашборды и настройки Grafana
│   └── provisioning/
│       ├── dashboards/         # JSON-файлы дашбордов
│       └── datasources/        # Подключение к БД
├── sql/
│   ├── build_calculated_views.sql   # Вьюхи для дашбордов
│   └── build_dimensions.sql         # Таблицы-справочники
├── scripts/
│   └── setup_users.sh          # Создание пользователей после загрузки данных
├── .github/workflows/
│   └── deploy.yml              # Автодеплой при push в main
├── docker-compose.remote.yml   # Конфигурация контейнеров
├── nginx.conf                  # Конфигурация Nginx
├── deploy.sh                   # Скрипт первого развёртывания
└── update.sh                   # Скрипт обновления сервера
```

---

## Первый запуск на сервере

### 1. Подключиться к серверу по SSH

```bash
ssh root@<IP_СЕРВЕРА>
```

### 2. Склонировать репозиторий и запустить деплой

```bash
git clone https://github.com/Greyswandir-gg/migration_package_v2.git /opt/analytics
cd /opt/analytics
bash deploy.sh
```

Скрипт сам:
- Установит Docker, если его нет
- Поднимет все контейнеры
- Применит SQL-структуру
- Настроит права папок Grafana
- Выведет ссылки для входа

#### Если порт 80 занят (например, стоит Caddy или другой Nginx)

```bash
bash deploy.sh --port 8081
```

#### Дополнительные параметры

```bash
bash deploy.sh --port 8081 --domain example.com --admin-pass МойПароль
```

| Параметр | По умолчанию | Описание |
|---|---|---|
| `--port` | авто (80 или 8081) | Порт для Nginx |
| `--domain` | IP сервера | Домен или IP для URL |
| `--dir` | `/opt/analytics` | Папка установки |
| `--admin-pass` | `admin` | Пароль Grafana admin |

### 3. Загрузить данные

После запуска открой **Admin App** и загрузи Excel-файл:

```
http://<IP>:<PORT>/app
```

Логин: `admin` / Пароль: `admin123`  
Используй **Full Refresh Upload** при первой загрузке.

### 4. Создать пользователей для сотрудников

После загрузки данных — запустить один раз:

```bash
bash /opt/analytics/scripts/setup_users.sh
```

Скрипт создаст Grafana-аккаунт для каждого сотрудника из Excel.  
Логин генерируется из имени: `"Иванов, Иван"` → `ivanov.ivan`  
Пароль по умолчанию для всех: **`Welcome2026!`**

---

## Обновление сервера

### Вариант 1 — Вручную (одна команда)

```bash
bash /opt/analytics/update.sh
```

Скрипт проверит наличие новых коммитов в GitHub, подтянет их и перезапустит изменившиеся контейнеры.

### Вариант 2 — Автодеплой при каждом push (см. следующий раздел)

---

## Автодеплой через GitHub Actions

При каждом `git push` в ветку `main` сервер обновляется автоматически за ~30 секунд.

### Настройка (один раз)

#### Шаг 1. Сгенерировать SSH-ключ на сервере

```bash
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy -N ""
cat ~/.ssh/github_deploy.pub >> ~/.ssh/authorized_keys
```

#### Шаг 2. Скопировать приватный ключ

```bash
cat ~/.ssh/github_deploy
```

Скопируй всё содержимое (от `-----BEGIN` до `-----END`).

#### Шаг 3. Добавить секреты в GitHub

Открой репозиторий → **Settings → Secrets and variables → Actions → New repository secret**

| Секрет | Значение |
|---|---|
| `SSH_HOST` | IP сервера, например `217.114.1.173` |
| `SSH_USER` | `root` |
| `SSH_KEY` | приватный ключ из шага 2 |
| `DEPLOY_PATH` | `/opt/analytics` |

После этого каждый `git push` в `main` автоматически обновит сервер.

---

## Работа с данными

### Загрузка / обновление данных

1. Открыть `http://<IP>:<PORT>/app`
2. Загрузить `.xlsx` файл
3. Выбрать **Full Refresh Upload** (полная перезапись) или **Append** (добавить)

### Пересоздать пользователей после обновления Excel

Если в Excel появились новые сотрудники — запустить:

```bash
bash /opt/analytics/scripts/setup_users.sh
```

Уже существующие пользователи не дублируются.

---

## Доступы

| Сервис | URL | Логин | Пароль |
|---|---|---|---|
| Grafana (admin) | `/grafana/` | `admin` | задаётся при деплое |
| Admin App | `/app` | `admin` | `admin123` |
| Grafana (сотрудник) | `/grafana/` | `фамилия.имя` | `Welcome2026!` |

Сотрудники видят только папку **Personal** со своим дашбордом.  
Все остальные дашборды доступны только Admin/Editor.

---

## Полезные команды

### Статус контейнеров

```bash
docker ps | grep migration_package_v2
```

### Логи

```bash
# Все контейнеры
docker compose -p migration_package_v2 -f /opt/analytics/docker-compose.remote.yml logs -f

# Конкретный сервис
docker compose -p migration_package_v2 -f /opt/analytics/docker-compose.remote.yml logs -f web_app
docker compose -p migration_package_v2 -f /opt/analytics/docker-compose.remote.yml logs -f grafana
```

### Перезапустить все контейнеры

```bash
docker compose -p migration_package_v2 -f /opt/analytics/docker-compose.remote.yml restart
```

### Полная остановка

```bash
docker compose -p migration_package_v2 -f /opt/analytics/docker-compose.remote.yml down
```

### Войти в базу данных

```bash
docker exec -it migration_package_v2-db-1 psql -U admin -d analytics_db
```

### Сбросить пароль сотрудника в Grafana

```bash
docker exec migration_package_v2-grafana-1 \
  curl -s -u admin:admin -X PUT http://127.0.0.1:3000/grafana/api/admin/users/<USER_ID>/password \
  -H "Content-Type: application/json" \
  -d '{"password":"НовыйПароль123!"}'
```
