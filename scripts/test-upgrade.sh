#!/usr/bin/env bash
set -Eeuo pipefail

OLD_VERSION="${OLD_VERSION:-v3.0.3}"
NEW_VERSION="${NEW_VERSION:-v3.2.2}"
OLD_VALKEY_IMAGE="${OLD_VALKEY_IMAGE:-docker.io/valkey/valkey:9@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9}"
NEW_VALKEY_IMAGE="${NEW_VALKEY_IMAGE:-docker.io/valkey/valkey:9@sha256:70739f85ad2ee01a726a965584a0f94895f01b0c60b3cc8b0aeef11eaa6888cf}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23}"

TEST_ROOT="${TEST_ROOT:-$(mktemp -d)}"
export COMPOSE_PROJECT_NAME="immich_upgrade_${GITHUB_RUN_ID:-local}_${GITHUB_RUN_ATTEMPT:-1}"
export UPLOAD_LOCATION="$TEST_ROOT/photos"
export DB_DATA_LOCATION="$TEST_ROOT/postgres"
export MODEL_CACHE_LOCATION="$TEST_ROOT/model-cache"
export DB_USERNAME=postgres
export DB_PASSWORD=postgres
export DB_DATABASE_NAME=immich

mkdir -p "$UPLOAD_LOCATION" "$DB_DATA_LOCATION" "$MODEL_CACHE_LOCATION"

cleanup() {
  docker compose --file "$TEST_ROOT/compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ "${KEEP_UPGRADE_TEST_DATA:-false}" != "true" ]]; then
    rm -rf "$TEST_ROOT"
  fi
}
trap cleanup EXIT

cat >"$TEST_ROOT/compose.yml" <<'YAML'
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION}
    environment:
      TZ: Asia/Shanghai
      DB_HOSTNAME: database
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_DATABASE_NAME: ${DB_DATABASE_NAME}
      REDIS_HOSTNAME: redis
      IMMICH_MACHINE_LEARNING_URL: http://immich-machine-learning:3003
    volumes:
      - ${UPLOAD_LOCATION}:/data
    ports:
      - "127.0.0.1:2283:2283"
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      disable: false

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION}
    environment:
      MACHINE_LEARNING_WORKERS: "1"
      MACHINE_LEARNING_WORKER_TIMEOUT: "120"
    volumes:
      - ${MODEL_CACHE_LOCATION}:/cache
    healthcheck:
      disable: false

  redis:
    image: ${VALKEY_IMAGE}
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 5s
      timeout: 3s
      retries: 30

  database:
    image: ${POSTGRES_IMAGE}
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: --data-checksums
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    healthcheck:
      disable: false
YAML

wait_healthy() {
  local service="$1"
  local deadline=$((SECONDS + 600))
  local container status
  while (( SECONDS < deadline )); do
    container="$(docker compose --file "$TEST_ROOT/compose.yml" ps --quiet "$service")"
    if [[ -n "$container" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")"
      if [[ "$status" == "healthy" ]]; then
        return 0
      fi
      if [[ "$status" == "unhealthy" || "$(docker inspect --format '{{.State.Status}}' "$container")" == "exited" ]]; then
        docker compose --file "$TEST_ROOT/compose.yml" logs --no-color "$service"
        return 1
      fi
    fi
    sleep 5
  done
  docker compose --file "$TEST_ROOT/compose.yml" logs --no-color "$service"
  echo "Timed out waiting for $service to become healthy" >&2
  return 1
}

start_release() {
  export IMMICH_VERSION="$1"
  export VALKEY_IMAGE="$2"
  docker compose --file "$TEST_ROOT/compose.yml" pull
  docker compose --file "$TEST_ROOT/compose.yml" up --detach --remove-orphans
  wait_healthy database
  wait_healthy redis
  wait_healthy immich-machine-learning
  wait_healthy immich-server
}

migration_count() {
  local migration_table
  migration_table="$(docker compose --file "$TEST_ROOT/compose.yml" exec -T database \
    psql --username "$DB_USERNAME" --dbname "$DB_DATABASE_NAME" --tuples-only --no-align \
    --command "SELECT quote_ident(table_schema) || '.' || quote_ident(table_name)
               FROM information_schema.tables
               WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
                 AND table_name ILIKE '%migration%'
               ORDER BY CASE WHEN table_name = 'migrations' THEN 0 ELSE 1 END, table_name
               LIMIT 1;" | tr -d '\r\n')"
  [[ -n "$migration_table" ]] || { echo "Immich migration table was not found" >&2; return 1; }
  docker compose --file "$TEST_ROOT/compose.yml" exec -T database \
    psql --username "$DB_USERNAME" --dbname "$DB_DATABASE_NAME" --tuples-only --no-align \
    --command "SELECT count(*) FROM $migration_table;"
}

echo "Starting Immich $OLD_VERSION"
start_release "$OLD_VERSION" "$OLD_VALKEY_IMAGE"

before_migrations="$(migration_count | tr -d '[:space:]')"
[[ "$before_migrations" =~ ^[0-9]+$ ]] || { echo "Invalid pre-upgrade migration count: $before_migrations" >&2; exit 1; }

docker compose --file "$TEST_ROOT/compose.yml" exec -T database \
  psql --username "$DB_USERNAME" --dbname "$DB_DATABASE_NAME" --set ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS lazycat_upgrade_test;
CREATE TABLE IF NOT EXISTS lazycat_upgrade_test.marker (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO lazycat_upgrade_test.marker (id, value)
VALUES (1, 'created-on-3.0.3')
ON CONFLICT (id) DO UPDATE SET value = excluded.value;
SQL
printf 'created-on-3.0.3\n' >"$UPLOAD_LOCATION/lazycat-upgrade-marker.txt"

echo "Recreating the four-service stack with Immich $NEW_VERSION"
docker compose --file "$TEST_ROOT/compose.yml" down --remove-orphans
start_release "$NEW_VERSION" "$NEW_VALKEY_IMAGE"

after_migrations="$(migration_count | tr -d '[:space:]')"
[[ "$after_migrations" =~ ^[0-9]+$ ]] || { echo "Invalid post-upgrade migration count: $after_migrations" >&2; exit 1; }
(( after_migrations >= before_migrations )) || {
  echo "Migration count decreased: $before_migrations -> $after_migrations" >&2
  exit 1
}

marker="$(docker compose --file "$TEST_ROOT/compose.yml" exec -T database \
  psql --username "$DB_USERNAME" --dbname "$DB_DATABASE_NAME" --tuples-only --no-align \
  --command 'SELECT value FROM lazycat_upgrade_test.marker WHERE id = 1;' | tr -d '\r\n')"
[[ "$marker" == "created-on-3.0.3" ]] || { echo "Database marker was not preserved" >&2; exit 1; }
grep -qx 'created-on-3.0.3' "$UPLOAD_LOCATION/lazycat-upgrade-marker.txt"

published_port="$(docker compose --file "$TEST_ROOT/compose.yml" port immich-server 2283 | awk -F: '{print $NF}')"
curl --fail --silent --show-error "http://127.0.0.1:${published_port}/api/server/ping" >/dev/null

echo "Upgrade verified: $OLD_VERSION -> $NEW_VERSION; migrations $before_migrations -> $after_migrations; database and photo storage preserved."
