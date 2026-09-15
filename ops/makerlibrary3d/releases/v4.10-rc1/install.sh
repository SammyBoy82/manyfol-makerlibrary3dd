#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="4.10-rc1"
BASE_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.9.1"
TARGET_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.10-rc1"
REPOSITORY="https://github.com/SammyBoy82/manyfol-makerlibrary3dd.git"
BRANCH="feature/makerlibrary3d-v4.10-membership"
REQUIRED_COMMIT="1a79f61fd15799bab4c5687709e8452a304786d7"
SOURCE="/srv/slforge/source/manyfol-makerlibrary3dd"
STACK="/srv/slforge/docker/stack"
CONTAINER="slforge-manyfold"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE="/srv/slforge/releases/makerlibrary3d-v4.10-rc1-$STAMP"
CHECKOUT="$RELEASE/checkout"
BACKUP="$RELEASE/backup"
OVERRIDE="$STACK/docker-compose.storage-v4.10-rc1.yml"
REPORT="/tmp/MakerLibrary3D-v4.10-rc1-result-$STAMP.txt"
LOG="/tmp/MakerLibrary3D-v410-rc1-$STAMP.log"
BUILD_CONTAINER="makerlibrary3d-v410-build-$STAMP"
TEST_NETWORK="makerlibrary3d-v410-test-$STAMP"
TEST_DB_CONTAINER="makerlibrary3d-v410-postgres-$STAMP"
TEST_DB_USER="makerlibrary_test"
TEST_DB_NAME="makerlibrary_test"
TEST_DB_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
DEPLOYED=0

RUNTIME_FILES=(
  app/controllers/settings/invitations_controller.rb
  app/models/user.rb
  app/views/devise/mailer/invitation_instructions.html.erb
  app/views/devise/mailer/invitation_instructions.text.erb
  app/views/layouts/settings.html.erb
  app/views/settings/invitations/index.html.erb
  app/views/settings/users/index.html.erb
  config/routes/moderation.rb
)
SOURCE_FILES=(
  "${RUNTIME_FILES[@]}"
  spec/requests/settings/invitations_spec.rb
)

exec > >(tee -a "$LOG") 2>&1

die() {
  echo "STOPPED: $*" >&2
  exit 1
}

job_gate() {
  docker exec --user 1500:1500 "$CONTAINER" bin/rails runner '
    require "json"
    require "sidekiq/api"
    running = Sidekiq::WorkSet.new.size
    queued = Sidekiq::Queue.all.sum(&:size)
    scheduled = Sidekiq::ScheduledSet.new.size
    retries = Sidekiq::RetrySet.new
    classes = retries.each_with_object(Hash.new(0)) { |job, h| h[job.display_class] += 1 }
    puts "SIDEKIQ_COUNTS=#{JSON.generate(running: running, queued: queued, scheduled: scheduled, retries: retries.size, retry_classes: classes)}"
    unexpected = classes.keys - ["Federails::NotifyInboxJob"]
    abort "Queues or jobs are active" unless running.zero? && queued.zero? && scheduled.zero? && unexpected.empty?
    puts "JOB_GATE=PASS"
  '
}

rollback() {
  set +e
  echo "========== AUTOMATIC ROLLBACK =========="
  if [ -x "$RELEASE/rollback.sh" ]; then
    bash "$RELEASE/rollback.sh"
  fi
}

cleanup_test_environment() {
  docker rm -f "$TEST_DB_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$TEST_NETWORK" >/dev/null 2>&1 || true
}

failed() {
  rc=$?
  cleanup_test_environment
  echo "FAILED at line $1 (exit $rc)"
  [ "$DEPLOYED" -eq 0 ] || rollback
  echo "LOG=$LOG"
  echo "RELEASE=$RELEASE"
  exit "$rc"
}
trap 'failed $LINENO' ERR

[ "$(id -u)" -eq 0 ] || die "run with sudo"
for command in docker git rsync curl python3; do
  command -v "$command" >/dev/null || die "missing command: $command"
done

echo "LOG=$LOG"
echo "MakerLibrary3D v4.10-rc1 — one-go installer"
echo
echo "========== PREFLIGHT =========="

[ -d "$SOURCE" ] || die "authoritative source is missing"
[ -d "$STACK" ] || die "Compose stack is missing"

CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
CURRENT_STATUS="$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
PROPAGATION="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/storage-sources"}}{{.Propagation}}{{end}}{{end}}')"

echo "current_image=$CURRENT_IMAGE"
echo "current_status=$CURRENT_STATUS"
echo "storage_propagation=$PROPAGATION"

[ "$CURRENT_IMAGE" = "$BASE_IMAGE" ] || die "production is not on the v4.9.1 baseline"
[ "$CURRENT_STATUS" = "running" ] || die "Manyfold is not running"
[ "$PROPAGATION" = "rshared" ] || die "storage propagation is not rshared"

job_gate

mkdir -p "$CHECKOUT" "$BACKUP/source"
git clone --quiet --depth 50 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
HEAD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD ||
  die "the GitHub branch does not contain the reviewed v4.10 code"
echo "github_head=$HEAD_SHA"

for path in "${SOURCE_FILES[@]}"; do
  [ -f "$CHECKOUT/$path" ] || die "release file missing: $path"
done

echo
echo "========== BACKUP =========="

: > "$BACKUP/existing.txt"
: > "$BACKUP/new.txt"
for path in "${SOURCE_FILES[@]}"; do
  if [ -f "$SOURCE/$path" ]; then
    mkdir -p "$BACKUP/source/$(dirname "$path")"
    cp -a "$SOURCE/$path" "$BACKUP/source/$path"
    echo "$path" >> "$BACKUP/existing.txt"
  else
    echo "$path" >> "$BACKUP/new.txt"
  fi
done

if [ -f "$OVERRIDE" ]; then
  cp -a "$OVERRIDE" "$BACKUP/override.yml"
  echo existing > "$BACKUP/override-state"
else
  echo new > "$BACKUP/override-state"
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
echo "========== BUILD CANDIDATE IMAGE =========="

if docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
  echo "Removing stale unpublished candidate image..."
  docker image rm "$TARGET_IMAGE" >/dev/null
fi

docker create --name "$BUILD_CONTAINER" "$BASE_IMAGE" >/dev/null

for path in "${RUNTIME_FILES[@]}"; do
  if [ "$path" = "app/views/settings/invitations/index.html.erb" ]; then
    docker cp "$CHECKOUT/app/views/settings/invitations" "$BUILD_CONTAINER:/usr/src/app/app/views/settings/"
  else
    docker cp "$CHECKOUT/$path" "$BUILD_CONTAINER:/usr/src/app/$path"
  fi
done

docker cp "$CHECKOUT/spec/requests/settings/invitations_spec.rb" "$BUILD_CONTAINER:/usr/src/app/spec/requests/settings/invitations_spec.rb"

docker commit \
  --change "LABEL com.slforge.version=$VERSION" \
  --change "LABEL com.slforge.source_commit=$HEAD_SHA" \
  --change "LABEL com.slforge.source_branch=$BRANCH" \
  "$BUILD_CONTAINER" "$TARGET_IMAGE" >/dev/null

docker rm "$BUILD_CONTAINER" >/dev/null

echo
echo "========== STATIC VALIDATION =========="

docker run --rm --entrypoint ruby "$TARGET_IMAGE"   -c /usr/src/app/app/controllers/settings/invitations_controller.rb
docker run --rm --entrypoint ruby "$TARGET_IMAGE"   -c /usr/src/app/app/models/user.rb

echo "RAILS_TEMPLATE_VALIDATION=REQUEST_SPEC"

echo
echo "========== ISOLATED REQUEST TEST =========="

DATABASE_SERVICE="$(
  docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    sed -n 's/^DATABASE_HOST=//p' |
    head -1
)"
[ -n "$DATABASE_SERVICE" ] || die "production database service could not be identified"

PRODUCTION_DB_CONTAINER="$(
  docker ps \
    --filter "label=com.docker.compose.project=slforge" \
    --filter "label=com.docker.compose.service=$DATABASE_SERVICE" \
    --format '{{.Names}}' |
    head -1
)"
[ -n "$PRODUCTION_DB_CONTAINER" ] || die "production database container could not be identified"

TEST_DB_IMAGE="$(docker inspect "$PRODUCTION_DB_CONTAINER" --format '{{.Config.Image}}')"
[ -n "$TEST_DB_IMAGE" ] || die "production PostgreSQL image could not be identified"

cleanup_test_environment
docker network create --internal "$TEST_NETWORK" >/dev/null

docker run -d \
  --name "$TEST_DB_CONTAINER" \
  --network "$TEST_NETWORK" \
  -e POSTGRES_USER="$TEST_DB_USER" \
  -e POSTGRES_PASSWORD="$TEST_DB_PASSWORD" \
  -e POSTGRES_DB="$TEST_DB_NAME" \
  "$TEST_DB_IMAGE" >/dev/null

TEST_DB_READY=0
for attempt in $(seq 1 30); do
  if docker exec "$TEST_DB_CONTAINER" \
       pg_isready -U "$TEST_DB_USER" -d "$TEST_DB_NAME" >/dev/null 2>&1
  then
    TEST_DB_READY=1
    break
  fi
  sleep 2
done
[ "$TEST_DB_READY" -eq 1 ] || die "disposable PostgreSQL test database did not become ready"

TEST_DATABASE_URL="postgresql://$TEST_DB_USER:$TEST_DB_PASSWORD@$TEST_DB_CONTAINER:5432/$TEST_DB_NAME"

docker run --rm \
  --network "$TEST_NETWORK" \
  -e RAILS_ENV=test \
  -e DATABASE_ADAPTER=postgresql \
  -e DATABASE_URL="$TEST_DATABASE_URL" \
  -e REDIS_URL=redis://127.0.0.1:1/15 \
  --entrypoint sh \
  "$TARGET_IMAGE" \
  -lc '
    bin/rails db:prepare &&
    bundle exec rspec spec/requests/settings/invitations_spec.rb
  '

cleanup_test_environment
echo "REQUEST_TEST_DATABASE=DISPOSABLE_POSTGRESQL"
echo "REQUEST_TEST_GATE=PASS"

cat > "$OVERRIDE" <<YAML
services:
  manyfold:
    image: $TARGET_IMAGE
YAML
chmod 0644 "$OVERRIDE"

COMPOSE_ARGS=(-p slforge)
while IFS= read -r file; do
  COMPOSE_ARGS+=(-f "$file")
done < "$RELEASE/compose-files.txt"
COMPOSE_ARGS+=(-f "$OVERRIDE")

docker compose "${COMPOSE_ARGS[@]}" config >/dev/null
echo "COMPOSE_GATE=PASS"

cat > "$RELEASE/rollback.sh" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

while IFS= read -r path; do
  [ -n "\$path" ] || continue
  mkdir -p "$SOURCE/\$(dirname "\$path")"
  cp -a "$BACKUP/source/\$path" "$SOURCE/\$path"
done < "$BACKUP/existing.txt"

while IFS= read -r path; do
  [ -n "\$path" ] || continue
  rm -f "$SOURCE/\$path"
done < "$BACKUP/new.txt"

ROLLBACK_OVERRIDE="$STACK/docker-compose.rollback-v4.9.1.yml"
cat > "\$ROLLBACK_OVERRIDE" <<YAML
services:
  manyfold:
    image: $BASE_IMAGE
YAML

ARGS=(-p slforge)
while IFS= read -r file; do
  ARGS+=(-f "\$file")
done < "$RELEASE/compose-files.txt"
ARGS+=(-f "\$ROLLBACK_OVERRIDE")

docker compose "\${ARGS[@]}" up -d --no-deps --force-recreate manyfold

for attempt in \$(seq 1 36); do
  docker exec --user 1500:1500 slforge-manyfold     bin/rails runner 'puts "ROLLBACK_READY=true"' >/dev/null 2>&1 && break
  sleep 5
done

docker exec --user 1500:1500 slforge-manyfold   bin/rails runner 'puts "ROLLBACK_READY=true"'
echo "ROLLBACK_OK=true"
ROLLBACK
chmod 0700 "$RELEASE/rollback.sh"

job_gate

echo
echo "========== DEPLOY RC1 =========="

docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps --force-recreate manyfold
DEPLOYED=1

for attempt in $(seq 1 36); do
  if docker exec --user 1500:1500 "$CONTAINER"       bin/rails runner 'puts "RAILS_READY=true"' >/dev/null 2>&1
  then
    break
  fi
  echo "Waiting for Manyfold startup..."
  sleep 5
done

echo
echo "========== ACCEPTANCE =========="

docker exec --user 1500:1500 "$CONTAINER" bin/rails runner '
  helpers = Rails.application.routes.url_helpers
  routes = {
    index: helpers.settings_invitations_path,
    resend: helpers.resend_settings_invitation_path(1),
    revoke: helpers.revoke_settings_invitation_path(1)
  }
  abort "Invitation controller missing" unless defined?(Settings::InvitationsController)
  abort "Invitation callback missing" unless User.respond_to?(:after_invitation_accepted)
  puts "INVITATION_ROUTES=#{routes.to_json}"
  puts "INVITATION_RUNTIME_GATE=PASS"
'

RUNTIME_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
RUNTIME_STATUS="$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
RUNTIME_PROPAGATION="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/storage-sources"}}{{.Propagation}}{{end}}{{end}}')"

[ "$RUNTIME_IMAGE" = "$TARGET_IMAGE" ]
[ "$RUNTIME_STATUS" = "running" ]
[ "$RUNTIME_PROPAGATION" = "rshared" ]

curl -fsS --max-time 30 https://library.makerlibrary3d.store/health >/dev/null
echo "HTTP_GATE=PASS"
job_gate

echo
echo "========== SYNC AUTHORITATIVE SOURCE =========="

for path in "${SOURCE_FILES[@]}"; do
  mkdir -p "$SOURCE/$(dirname "$path")"
  rsync -a --checksum "$CHECKOUT/$path" "$SOURCE/$path"
  cmp -s "$CHECKOUT/$path" "$SOURCE/$path"
done
echo "SOURCE_SYNC_GATE=PASS"

cat > "$REPORT" <<REPORT
MakerLibrary3D v4.10-rc1
accepted_utc=$STAMP
image=$TARGET_IMAGE
source_commit=$HEAD_SHA
source_branch=$BRANCH
container_status=$RUNTIME_STATUS
storage_propagation=$RUNTIME_PROPAGATION
invitation_runtime_gate=pass
request_test_gate=pass
http_gate=pass
job_gate=pass
source_sync=pass
rollback=sudo bash $RELEASE/rollback.sh
REPORT
chmod 0600 "$REPORT"

DEPLOYED=0
trap - ERR

echo
echo "========== COMPLETE =========="
echo "DEPLOYMENT_OK=true"
echo "VERSION=$VERSION"
echo "IMAGE=$TARGET_IMAGE"
echo "SOURCE_COMMIT=$HEAD_SHA"
echo "REPORT=$REPORT"
echo "RELEASE=$RELEASE"
echo "ROLLBACK=sudo bash $RELEASE/rollback.sh"
