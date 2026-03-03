@echo off
REM Синхронизация пользователей Grafana из базы данных
REM Создаёт пользователей с паролем 23456789 для всех owner_login из work_logs

echo Запуск синхронизации пользователей Grafana...
docker compose -f docker-compose.remote.yml --profile tools run --rm sync_grafana_users
pause
