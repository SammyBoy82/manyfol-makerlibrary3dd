#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="4.10-rc1"
EXPECTED_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.10-rc1"
CONTAINER="slforge-manyfold"
STACK="/srv/slforge/docker/stack"
MAIL_DIR="/etc/slforge-mail"
ENV_FILE="$MAIL_DIR/smtp.env"
OVERRIDE="$STACK/docker-compose.mail-v4.10-rc1.yml"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE="/srv/slforge/releases/makerlibrary3d-mail-v4.10-rc1-$STAMP"
BACKUP="$RELEASE/backup"
REPORT="/tmp/MakerLibrary3D-mail-v4.10-rc1-result-$STAMP.txt"
LOG="/tmp/MakerLibrary3D-mail-v410-$STAMP.log"
DEPLOYED=0
CONFIG_CHANGED=0

exec > >(tee -a "$LOG") 2>&1

die() {
  echo "STOPPED: $*" >&2
  exit 1
}

restore_files() {
  if [ -f "$BACKUP/env.exists" ]; then
    install -d -m 0700 "$MAIL_DIR"
    cp -a "$BACKUP/smtp.env" "$ENV_FILE"
  else
    rm -f "$ENV_FILE"
  fi

  if [ -f "$BACKUP/override.exists" ]; then
    cp -a "$BACKUP/compose.yml" "$OVERRIDE"
  else
    rm -f "$OVERRIDE"
  fi
}

rollback() {
  set +e
  echo "========== AUTOMATIC MAIL ROLLBACK =========="

  restore_files

  ARGS=(-p slforge)
  while IFS= read -r file; do
    [ -n "$file" ] && ARGS+=(-f "$file")
  done < "$RELEASE/compose-files.txt"

  docker compose "${ARGS[@]}" up -d --no-deps --force-recreate manyfold

  for attempt in $(seq 1 36); do
    if docker exec --user 1500:1500 "$CONTAINER" \
         bin/rails runner 'puts "ROLLBACK_READY=true"' >/dev/null 2>&1
    then
      break
    fi
    sleep 5
  done

  docker exec --user 1500:1500 "$CONTAINER" \
    bin/rails runner 'puts "ROLLBACK_READY=true"'
  echo "MAIL_ROLLBACK_OK=true"
}

failed() {
  rc=$?
  echo "FAILED at line $1 (exit $rc)"
  if [ "$DEPLOYED" -ne 0 ]; then
    rollback
  elif [ "$CONFIG_CHANGED" -ne 0 ]; then
    restore_files
    echo "UNAPPLIED_MAIL_CONFIG_RESTORED=true"
  fi
  echo "LOG=$LOG"
  echo "RELEASE=$RELEASE"
  exit "$rc"
}
trap 'failed $LINENO' ERR

[ "$(id -u)" -eq 0 ] || die "run with sudo"
for command in docker python3 curl install; do
  command -v "$command" >/dev/null || die "missing command: $command"
done

echo "LOG=$LOG"
echo "MakerLibrary3D SMTP2GO configuration — $VERSION"
echo
echo "========== PREFLIGHT =========="

[ -d "$STACK" ] || die "Compose stack is missing"

CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
CURRENT_STATUS="$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "current_image=$CURRENT_IMAGE"
echo "current_status=$CURRENT_STATUS"

[ "$CURRENT_IMAGE" = "$EXPECTED_IMAGE" ] || die "production is not on v4.10-rc1"
[ "$CURRENT_STATUS" = "running" ] || die "Manyfold is not running"

docker exec --user 1500:1500 "$CONTAINER" bin/rails runner '
  require "sidekiq/api"
  running = Sidekiq::WorkSet.new.size
  queued = Sidekiq::Queue.all.sum(&:size)
  scheduled = Sidekiq::ScheduledSet.new.size
  abort "Queues or jobs are active" unless running.zero? && queued.zero? && scheduled.zero?
  puts "JOB_GATE=PASS"
'

DEFAULT_FROM="notifications@makerlibrary3d.store"
read -r -p "Verified sender address [$DEFAULT_FROM]: " SMTP_FROM_INPUT
SMTP_FROM_INPUT="${SMTP_FROM_INPUT:-$DEFAULT_FROM}"
read -r -p "Test recipient address: " SMTP_TEST_RECIPIENT
read -r -s -p "SMTP2GO password for makers3dlibrarysmtp: " SMTP_PASSWORD_INPUT
echo

[[ "$SMTP_FROM_INPUT" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
  die "invalid sender address"
[[ "$SMTP_TEST_RECIPIENT" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
  die "invalid test recipient address"
[ -n "$SMTP_PASSWORD_INPUT" ] || die "SMTP password is empty"

SMTP_DOMAIN="${SMTP_FROM_INPUT##*@}"

echo
echo "========== SMTP2GO AUTHENTICATION TEST =========="

python3 - "mail.smtp2go.com" "2525" "makers3dlibrarysmtp" 3<<<"$SMTP_PASSWORD_INPUT" <<'PY'
import smtplib
import ssl
import sys

server, port, username = sys.argv[1], int(sys.argv[2]), sys.argv[3]
password = open("/dev/fd/3", encoding="utf-8").read().rstrip("\n")
with smtplib.SMTP(server, port, timeout=20) as smtp:
    smtp.ehlo()
    smtp.starttls(context=ssl.create_default_context())
    smtp.ehlo()
    smtp.login(username, password)
print("SMTP_AUTH_GATE=PASS")
PY

install -d -m 0700 "$RELEASE" "$BACKUP" "$MAIL_DIR"

if [ -f "$ENV_FILE" ]; then
  cp -a "$ENV_FILE" "$BACKUP/smtp.env"
  : > "$BACKUP/env.exists"
fi
if [ -f "$OVERRIDE" ]; then
  cp -a "$OVERRIDE" "$BACKUP/compose.yml"
  : > "$BACKUP/override.exists"
fi

CONFIG_LABEL="$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
[ -n "$CONFIG_LABEL" ] || die "active Compose files could not be discovered"

python3 - "$CONFIG_LABEL" "$RELEASE/compose-files.txt" <<'PY'
from pathlib import Path
import sys

paths = [Path(item.strip()) for item in sys.argv[1].split(",") if item.strip()]
if not paths:
    raise SystemExit("No active Compose files found")
for path in paths:
    if not path.is_file():
        raise SystemExit(f"Active Compose file is missing: {path}")
Path(sys.argv[2]).write_text("\n".join(map(str, paths)) + "\n", encoding="utf-8")
PY

echo
echo "========== WRITE ROOT-ONLY MAIL CONFIGURATION =========="

CONFIG_CHANGED=1
{
  echo "SMTP_SERVER=mail.smtp2go.com"
  echo "SMTP_PORT=2525"
  echo "SMTP_DOMAIN=$SMTP_DOMAIN"
  echo "SMTP_USERNAME=makers3dlibrarysmtp"
  printf 'SMTP_PASSWORD=%s\n' "$SMTP_PASSWORD_INPUT"
  echo "SMTP_AUTHENTICATION=plain"
  echo "SMTP_OPENSSL_VERIFY_MODE=peer"
  echo "SMTP_OPEN_TIMEOUT=15"
  echo "SMTP_READ_TIMEOUT=30"
  echo "SMTP_FROM_ADDRESS=$SMTP_FROM_INPUT"
} > "$ENV_FILE"
chmod 0600 "$ENV_FILE"
unset SMTP_PASSWORD_INPUT

cat > "$OVERRIDE" <<YAML
services:
  manyfold:
    env_file:
      - path: $ENV_FILE
        format: raw
YAML
chmod 0600 "$OVERRIDE"

ARGS=(-p slforge)
while IFS= read -r file; do
  [ -n "$file" ] && ARGS+=(-f "$file")
done < "$RELEASE/compose-files.txt"
ARGS+=(-f "$OVERRIDE")

docker compose "${ARGS[@]}" config >/dev/null
echo "COMPOSE_MAIL_GATE=PASS"

echo
echo "========== DEPLOY MAIL CONFIGURATION =========="

DEPLOYED=1
docker compose "${ARGS[@]}" up -d --no-deps --force-recreate manyfold

READY=0
for attempt in $(seq 1 36); do
  if docker exec --user 1500:1500 "$CONTAINER" \
       bin/rails runner 'puts "RAILS_READY=true"' >/dev/null 2>&1
  then
    READY=1
    break
  fi
  echo "Waiting for Manyfold startup..."
  sleep 5
done
[ "$READY" -eq 1 ] || die "Manyfold did not become ready"

echo
echo "========== PRODUCTION SMTP DELIVERY TEST =========="

docker exec \
  --user 1500:1500 \
  -e SMTP_TEST_RECIPIENT="$SMTP_TEST_RECIPIENT" \
  "$CONTAINER" \
  bin/rails runner '
    abort "Email configuration is not enabled" unless SiteSettings.email_configured?
    settings = Rails.application.config.action_mailer.smtp_settings
    abort "Unexpected SMTP server" unless settings[:address] == "mail.smtp2go.com"
    abort "Unexpected SMTP port" unless settings[:port].to_i == 2525
    abort "SMTP password is unavailable" if settings[:password].to_s.empty?

    message = ActionMailer::Base.mail(
      from: ENV.fetch("SMTP_FROM_ADDRESS"),
      to: ENV.fetch("SMTP_TEST_RECIPIENT"),
      subject: "MakerLibrary3D SMTP delivery test",
      body: "MakerLibrary3D SMTP2GO delivery is configured successfully."
    )
    message.deliver_now

    puts "SMTP_CONFIG_GATE=PASS"
    puts "SMTP_DELIVERY_GATE=PASS"
    puts "message_id=#{message.message_id}"
  '

RUNTIME_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
RUNTIME_STATUS="$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
[ "$RUNTIME_IMAGE" = "$EXPECTED_IMAGE" ]
[ "$RUNTIME_STATUS" = "running" ]

curl -fsS --max-time 30 https://library.makerlibrary3d.store/health >/dev/null
echo "HTTP_GATE=PASS"

cat > "$REPORT" <<REPORT
MakerLibrary3D SMTP2GO configuration
configured_utc=$STAMP
version=$VERSION
image=$RUNTIME_IMAGE
smtp_server=mail.smtp2go.com
smtp_port=2525
smtp_username=makers3dlibrarysmtp
smtp_domain=$SMTP_DOMAIN
smtp_from=$SMTP_FROM_INPUT
test_recipient=$SMTP_TEST_RECIPIENT
smtp_auth_gate=pass
smtp_delivery_gate=pass
http_gate=pass
mail_env=$ENV_FILE
compose_override=$OVERRIDE
REPORT
chmod 0600 "$REPORT"

DEPLOYED=0
trap - ERR

echo
echo "========== COMPLETE =========="
echo "SMTP_CONFIGURATION_OK=true"
echo "SMTP_DELIVERY_OK=true"
echo "FROM=$SMTP_FROM_INPUT"
echo "TEST_RECIPIENT=$SMTP_TEST_RECIPIENT"
echo "REPORT=$REPORT"
echo "RELEASE=$RELEASE"
