#!/bin/bash

# Wait PostgreSQL service
until pg_isready -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER"; do
  echo "Waiting for PostgreSQL to start..."
  sleep 2
done

# Run sql
PGPASSWORD=$DATABASE_PASS psql -h "$DATABASE_HOST" -U "$DATABASE_USER" -d "teslamate" -f /proc.sql

# Run Grafana
/run.sh
