#!/bin/bash

# 等待PostgreSQL服务启动
until pg_isready -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER"; do
  echo "Waiting for PostgreSQL to start..."
  sleep 2
done

# 执行初始化SQL脚本
PGPASSWORD=$DATABASE_PASS psql -h "$DATABASE_HOST" -U "$DATABASE_USER" -d "teslamate" -f /proc.sql

# 启动Grafana
# 测试打包
/run.sh
