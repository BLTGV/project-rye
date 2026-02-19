#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${RYE_DOCKER_COMPOSE_FILE:-docker-compose.yml}"
POSTGRES_USER="${POSTGRES_USER:-rye}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-rye}"
POSTGRES_DB="${POSTGRES_DB:-rye}"
PROFILES="${RYE_PROFILES:-crm,pm}"
SEED=1
RUN_CONFORMANCE=1
KEEP_RUNNING=0
RESET=0
DOWN_VOLUMES=0

find_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi

  echo "Docker Compose is required (docker compose or docker-compose)." >&2
  exit 1
}

compose() {
  "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"
}

wait_for_db() {
  local attempts=60

  for ((i=1; i<=attempts; i++)); do
    if compose exec -T rye-db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      echo "Postgres is ready"
      return 0
    fi
    sleep 1
  done

  echo "Postgres did not become ready in time" >&2
  compose logs rye-db || true
  return 1
}

cmd_up() {
  if [[ "$RESET" -eq 1 ]]; then
    compose down -v --remove-orphans
  fi

  compose up -d rye-db
  wait_for_db

  echo "Container is up."
  echo "Host DSN: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${RYE_POSTGRES_PORT:-54329}/${POSTGRES_DB}"
}

cmd_down() {
  if [[ "$DOWN_VOLUMES" -eq 1 ]]; then
    compose down -v --remove-orphans
  else
    compose down --remove-orphans
  fi
}

cleanup_if_needed() {
  if [[ "$KEEP_RUNNING" -eq 0 ]]; then
    compose down --remove-orphans >/dev/null 2>&1 || true
  fi
}

cmd_test() {
  local container_dsn
  local install_cmd

  if [[ "$KEEP_RUNNING" -eq 0 ]]; then
    trap cleanup_if_needed EXIT
  fi

  cmd_up

  container_dsn="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"
  install_cmd="cd /workspace && DATABASE_URL='${container_dsn}' ./scripts/install.sh --profiles '${PROFILES}'"

  if [[ "$SEED" -eq 1 ]]; then
    install_cmd+=" --seed"
  fi

  compose exec -T rye-db bash -lc "$install_cmd"

  if [[ "$RUN_CONFORMANCE" -eq 1 ]]; then
    compose exec -T rye-db bash -lc "cd /workspace && DATABASE_URL='${container_dsn}' ./scripts/conformance.sh"
  fi

  echo "Docker test flow passed."

  if [[ "$KEEP_RUNNING" -eq 1 ]]; then
    echo "Container kept running."
    echo "Host DSN: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${RYE_POSTGRES_PORT:-54329}/${POSTGRES_DB}"
  fi
}

usage() {
  cat <<EOF
Usage:
  ./scripts/docker-test.sh [up|test|down] [options]

Commands:
  up                    Start postgres container and wait for readiness
  test                  Start container, run install + conformance flow
  down                  Stop container

Options:
  --profiles <list>     Profiles for install/test (default: crm,pm)
  --seed                Seed quickstart data during test (default)
  --no-seed             Skip seeding during test
  --skip-conformance    Run install only (no conformance)
  --keep-running        Keep container running after test
  --reset               Drop container + volume before up/test
  --volumes             With down, also remove volume

Examples:
  ./scripts/docker-test.sh test --reset --profiles crm,pm
  ./scripts/docker-test.sh up
  ./scripts/docker-test.sh down --volumes
EOF
}

main() {
  local command="test"

  if [[ $# -gt 0 && "$1" != -* ]]; then
    command="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profiles)
        PROFILES="${2:-}"
        shift 2
        ;;
      --seed)
        SEED=1
        shift
        ;;
      --no-seed)
        SEED=0
        shift
        ;;
      --skip-conformance)
        RUN_CONFORMANCE=0
        shift
        ;;
      --keep-running)
        KEEP_RUNNING=1
        shift
        ;;
      --reset)
        RESET=1
        shift
        ;;
      --volumes)
        DOWN_VOLUMES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  case "$command" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  find_compose_cmd

  case "$command" in
    up)
      cmd_up
      ;;
    test)
      cmd_test
      ;;
    down)
      cmd_down
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $command" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
