#!/bin/bash
# Runs on every container start: the image's Postgres cluster, with the garage_dev superuser
# GARAGE_TEST_DATABASE_URL names (devcontainer.json "remoteEnv"). Idempotent.
set -euo pipefail

MAJOR="$(ls /usr/lib/postgresql | sort -n | tail -1)"

if ! pg_lsclusters --no-header | grep -q "^$MAJOR  *main "; then
  sudo pg_createcluster "$MAJOR" main
fi
sudo pg_ctlcluster "$MAJOR" main start 2>/dev/null || true
for _ in $(seq 30); do
  pg_isready -q -h localhost -p 5432 && break
  sleep 1
done

# vscode may sudo only as root (the base image's sudoers): `sudo -u postgres` asks for a
# password, so become postgres through runuser instead.
sudo runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'garage_dev') THEN
    CREATE ROLE garage_dev LOGIN SUPERUSER PASSWORD 'garage_dev';
  END IF;
END
\$\$;" </dev/null
echo "[start-postgres] Postgres $MAJOR ready; GARAGE_TEST_DATABASE_URL=${GARAGE_TEST_DATABASE_URL:-unset}"
