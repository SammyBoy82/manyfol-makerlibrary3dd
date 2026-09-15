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
STAGED="$RELEASE/staged-code"
OVERRIDE="$STACK/docker-compose.storage-v4.10-rc1.yml"
REPORT="/tmp/MakerLibrary3D-v4.10-rc1-result-$STAMP.txt"
LOG="/tmp/MakerLibrary3D-v410-rc1-$STAMP.log"
BUILD_CONTAINER="makerlibrary3d-v410-build-$STAMP"
TEST_NETWORK="makerlibrary3d-v410-test-$STAMP"
TEST_DB_CONTAINER="makerlibrary3d-v410-postgres-$STAMP"
TEST_REDIS_CONTAINER="makerlibrary3d-v410-redis-$STAMP"
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
  docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$TEST_REDIS_CONTAINER" >/dev/null 2>&1 || true
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
trap cleanup_test_environment EXIT

[ "$(id -u)" -eq 0 ] || die "run with sudo"
for command in docker git rsync curl python3 install; do
  command -v "$command" >/dev/null || die "missing command: $command"
done

echo "LOG=$LOG"
echo "MakerLibrary3D v4.10-rc1 — UID 1500 packaging and integration gates"
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

# Keep checkout, backups and credentials private. Only allowlisted application
# code is staged with public-read permissions for the runtime UID.
echo "========== STAGE RUNTIME CODE =========="
for path in "${SOURCE_FILES[@]}"; do
  [ ! -L "$CHECKOUT/$path" ] || die "release file must not be a symlink: $path"
  (umask 022; mkdir -p "$STAGED/$(dirname "$path")")
  install -m 0644 "$CHECKOUT/$path" "$STAGED/$path"
  cmp -s "$CHECKOUT/$path" "$STAGED/$path"
done
echo "CODE_STAGING_GATE=PASS"


if docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
  echo "Removing stale unpublished candidate image..."
  docker image rm "$TARGET_IMAGE" >/dev/null
fi

docker create --name "$BUILD_CONTAINER" "$BASE_IMAGE" >/dev/null

for path in "${RUNTIME_FILES[@]}"; do
  if [ "$path" = "app/views/settings/invitations/index.html.erb" ]; then
    docker cp "$STAGED/app/views/settings/invitations" "$BUILD_CONTAINER:/usr/src/app/app/views/settings/"
  else
    docker cp "$STAGED/$path" "$BUILD_CONTAINER:/usr/src/app/$path"
  fi
done

docker cp "$STAGED/spec/requests/settings/invitations_spec.rb" "$BUILD_CONTAINER:/usr/src/app/spec/requests/settings/invitations_spec.rb"

docker commit \
  --change "LABEL com.slforge.version=$VERSION" \
  --change "LABEL com.slforge.source_commit=$HEAD_SHA" \
  --change "LABEL com.slforge.source_branch=$BRANCH" \
  "$BUILD_CONTAINER" "$TARGET_IMAGE" >/dev/null

docker rm "$BUILD_CONTAINER" >/dev/null

echo
echo "========== STATIC VALIDATION =========="

docker run --rm --network none --user 1500:1500 \
  --entrypoint ruby "$TARGET_IMAGE" -e '
    abort "Wrong runtime identity" unless Process.uid == 1500 && Process.gid == 1500
    ARGV.each do |relative|
      path = File.join("/usr/src/app", relative)
      File.open(path, "rb") { |file| file.read(1) }
      directory = File.dirname(path)
      loop do
        Dir.children(directory)
        break if directory == "/usr/src/app"
        directory = File.dirname(directory)
      end
    end
    puts "RUNTIME_CODE_ACCESS_GATE=PASS; UID=1500; GID=1500"
  ' "${SOURCE_FILES[@]}"


docker run --rm --user 1500:1500 --entrypoint ruby "$TARGET_IMAGE"   -c /usr/src/app/app/controllers/settings/invitations_controller.rb
docker run --rm --user 1500:1500 --entrypoint ruby "$TARGET_IMAGE"   -c /usr/src/app/app/models/user.rb

echo "RAILS_TEMPLATE_VALIDATION=INTEGRATION_SMOKE_TEST"

echo
echo "========== ISOLATED REQUEST TEST =========="

DATABASE_SERVICE="$(
  docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    sed -n 's/^DATABASE_HOST=//p' |
    head -1
)"

PRODUCTION_DB_CONTAINER=""
if [ -n "$DATABASE_SERVICE" ]; then
  PRODUCTION_DB_CONTAINER="$(
    docker ps \
      --filter "label=com.docker.compose.project=slforge" \
      --filter "label=com.docker.compose.service=$DATABASE_SERVICE" \
      --format '{{.Names}}' |
      head -1
  )"
fi

if [ -z "$PRODUCTION_DB_CONTAINER" ]; then
  PRODUCTION_DB_CONTAINER="$(
    docker ps \
      --filter "label=com.docker.compose.project=slforge" \
      --format '{{.Names}}|{{.Image}}' |
      awk -F '|' 'tolower($2) ~ /postgres/ { print $1; exit }'
  )"
fi
[ -n "$PRODUCTION_DB_CONTAINER" ] || die "production PostgreSQL container could not be identified"

PRODUCTION_REDIS_CONTAINER="$(
  docker ps \
    --filter "label=com.docker.compose.project=slforge" \
    --filter "label=com.docker.compose.service=redis" \
    --format '{{.Names}}' |
    head -1
)"

if [ -z "$PRODUCTION_REDIS_CONTAINER" ]; then
  PRODUCTION_REDIS_CONTAINER="$(
    docker ps \
      --filter "label=com.docker.compose.project=slforge" \
      --format '{{.Names}}|{{.Image}}' |
      awk -F '|' 'tolower($2) ~ /redis/ { print $1; exit }'
  )"
fi
[ -n "$PRODUCTION_REDIS_CONTAINER" ] || die "production Redis container could not be identified"

TEST_DB_IMAGE="$(docker inspect "$PRODUCTION_DB_CONTAINER" --format '{{.Config.Image}}')"
TEST_REDIS_IMAGE="$(docker inspect "$PRODUCTION_REDIS_CONTAINER" --format '{{.Config.Image}}')"
[ -n "$TEST_DB_IMAGE" ] || die "production PostgreSQL image could not be identified"
[ -n "$TEST_REDIS_IMAGE" ] || die "production Redis image could not be identified"

cleanup_test_environment
docker network create --internal "$TEST_NETWORK" >/dev/null

docker run -d \
  --name "$TEST_DB_CONTAINER" \
  --network "$TEST_NETWORK" \
  -e POSTGRES_USER="$TEST_DB_USER" \
  -e POSTGRES_PASSWORD="$TEST_DB_PASSWORD" \
  -e POSTGRES_DB="$TEST_DB_NAME" \
  "$TEST_DB_IMAGE" >/dev/null

docker run -d \
  --name "$TEST_REDIS_CONTAINER" \
  --network "$TEST_NETWORK" \
  "$TEST_REDIS_IMAGE" >/dev/null

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

TEST_REDIS_READY=0
for attempt in $(seq 1 30); do
  if docker exec "$TEST_REDIS_CONTAINER" redis-cli ping 2>/dev/null |
       grep -qx PONG
  then
    TEST_REDIS_READY=1
    break
  fi
  sleep 1
done
[ "$TEST_REDIS_READY" -eq 1 ] || die "disposable Redis test service did not become ready"

TEST_DATABASE_URL="postgresql://$TEST_DB_USER:$TEST_DB_PASSWORD@$TEST_DB_CONTAINER:5432/$TEST_DB_NAME"
TEST_REDIS_URL="redis://$TEST_REDIS_CONTAINER:6379/15"

if ! TEST_VITE_OUTPUT_DIR="$(
  docker run --rm \
    --entrypoint sh \
    "$TARGET_IMAGE" \
    -lc '
      for directory in \
        /usr/src/app/public/vite \
        /usr/src/app/public/vite-*
      do
        if [ -s "$directory/.vite/manifest.json" ] ||
           [ -s "$directory/manifest.json" ]
        then
          basename "$directory"
          exit 0
        fi
      done
      exit 1
    '
)"
then
  die "packaged Vite manifest could not be identified"
fi
[ -n "$TEST_VITE_OUTPUT_DIR" ] || die "packaged Vite manifest path was empty"
echo "vite_output_dir=$TEST_VITE_OUTPUT_DIR"
echo "VITE_PRODUCTION_MANIFEST_GATE=PASS"

# Writable scratch space belongs only to each disposable test container.
# Never mount over app/views or other code: the UID code-access gate stays real.
TEST_WRITABLE=(
  --tmpfs /usr/src/app/tmp:rw,nosuid,nodev,uid=1500,gid=1500,mode=0700,size=256m
  --tmpfs /usr/src/app/log:rw,nosuid,nodev,uid=1500,gid=1500,mode=0700,size=32m
  -e HOME=/tmp
)

docker run --rm --network none --user 1500:1500 \
  "${TEST_WRITABLE[@]}" --entrypoint ruby "$TARGET_IMAGE" -e '
    abort "Wrong runtime identity" unless Process.uid == 1500 && Process.gid == 1500
    ["/usr/src/app/tmp", "/usr/src/app/log"].each do |directory|
      path = File.join(directory, ".write-probe")
      File.write(path, "probe")
      abort "Scratch readback failed" unless File.read(path) == "probe"
      File.unlink(path)
    end
    puts "TEST_WRITABLE_DIRECTORIES_GATE=PASS"
  '

TEST_ENV=(
  -e RAILS_ENV=test
  -e APP_VERSION="$VERSION"
  -e GIT_SHA="$HEAD_SHA"
  -e MULTIUSER=enabled
  -e PUBLIC_HOSTNAME=example.com
  -e VITE_RUBY_AUTO_BUILD=false
  -e VITE_RUBY_PUBLIC_OUTPUT_DIR="$TEST_VITE_OUTPUT_DIR"
  -e DATABASE_ADAPTER=postgresql
  -e DATABASE_URL="$TEST_DATABASE_URL"
  -e REDIS_URL="$TEST_REDIS_URL"
)

docker run --rm --user 1500:1500 \
  --network "$TEST_NETWORK" \
  "${TEST_ENV[@]}" \
  "${TEST_WRITABLE[@]}" \
  --entrypoint sh \
  "$TARGET_IMAGE" \
  -lc 'bin/rails db:prepare >/dev/null'
echo "DATABASE_PREPARE_GATE=PASS"

docker run --rm -i --user 1500:1500 \
  --network "$TEST_NETWORK" \
  "${TEST_ENV[@]}" \
  "${TEST_WRITABLE[@]}" \
  --entrypoint sh \
  "$TARGET_IMAGE" \
  -lc 'bin/rails runner -' <<'RUBY'
require "action_dispatch/testing/integration"
require "fileutils"
require "securerandom"

def assert_gate(condition, message)
  raise "INTEGRATION_GATE_FAILED: #{message}" unless condition
end

assert_gate(Process.uid == 1500 && Process.gid == 1500, "test must run as runtime UID/GID 1500")
puts "INTEGRATION_RUNTIME_IDENTITY_GATE=PASS"

library_path = "/tmp/makerlibrary-v410-smoke-library"
FileUtils.mkdir_p(library_path)

Library.create!(
  name: "v4.10 Smoke Library",
  path: library_path,
  storage_service: "filesystem"
)

password = SecureRandom.base64(36)
administrator = User.create!(
  username: "v410_smoke_admin",
  email: "v410-smoke-admin@example.com",
  password: password,
  password_confirmation: password,
  approved: true,
  membership_status: "active"
)
administrator.add_role(:administrator)
assert_gate(administrator.is_administrator?, "administrator role was not assigned")
assert_gate(
  ActionMailer::Base.delivery_method.to_sym == :test,
  "mailer is not using the isolated test delivery method"
)

plan = MembershipPlan.create!(
  name: "v4.10 Smoke Plan",
  description: "Disposable integration validation",
  billing_interval: "month",
  active: true,
  all_libraries: true
)

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! "example.com"

session.post(
  "/users/sign_in",
  params: {
    user: {
      email: administrator.email,
      password: password
    }
  }
)
assert_gate(session.response.redirect?, "administrator sign-in failed")

session.get("/settings/invitations")
assert_gate(session.response.status == 200, "invitation dashboard did not return HTTP 200")
assert_gate(
  session.response.body.include?("Membership Invitations"),
  "invitation dashboard template did not render"
)

email = "v410-invited-member@example.com"
session.post(
  "/settings/invitations",
  params: {
    email: email,
    membership_role: "contributor",
    membership_plan_id: plan.id,
    membership_admin_notes: "Disposable integration validation"
  }
)
assert_gate(session.response.redirect?, "invitation creation did not redirect")

invitation = User.find_by(email: email)
assert_gate(invitation.present?, "invited user was not created")
assert_gate(invitation.invitation_token.present?, "invitation token was not created")
assert_gate(invitation.invitation_sent_at.present?, "invitation sent timestamp was not recorded")
assert_gate(invitation.invitation_due_at.present?, "invitation expiry was not calculated")
assert_gate(
  invitation.invitation_due_at.between?(13.days.from_now, 15.days.from_now),
  "invitation expiry is not approximately 14 days"
)
assert_gate(invitation.membership_plan_id == plan.id, "membership plan was not assigned")
assert_gate(invitation.has_role?(:member), "member role was not assigned")
assert_gate(invitation.has_role?(:contributor), "contributor role was not assigned")

user_count = User.count
session.post(
  "/settings/invitations",
  params: {
    email: email.upcase,
    membership_role: "member"
  }
)
assert_gate(User.count == user_count, "duplicate invitation was created")

invalid_role_count = User.count
session.post(
  "/settings/invitations",
  params: {
    email: "v410-invalid-role@example.com",
    membership_role: "owner"
  }
)
assert_gate(User.count == invalid_role_count, "unsupported role invitation was created")

original_token = invitation.invitation_token
session.post("/settings/invitations/#{invitation.id}/resend")
assert_gate(session.response.redirect?, "invitation resend did not redirect")
assert_gate(
  invitation.reload.invitation_token != original_token,
  "invitation resend did not rotate the token"
)

session.delete("/settings/invitations/#{invitation.id}/revoke")
assert_gate(session.response.redirect?, "invitation revoke did not redirect")
assert_gate(!User.exists?(invitation.id), "revoked invitation still exists")

audit_actions = AdminAuditEvent.where(
  action: [
    "membership_invitation_created",
    "membership_invitation_resent",
    "membership_invitation_revoked"
  ]
).distinct.pluck(:action)

assert_gate(
  audit_actions.sort == [
    "membership_invitation_created",
    "membership_invitation_resent",
    "membership_invitation_revoked"
  ].sort,
  "invitation audit events are incomplete"
)

puts "MAIL_DELIVERY_ISOLATION_GATE=PASS"
puts "INVITATION_DASHBOARD_RENDER_GATE=PASS"
puts "INVITATION_CREATE_GATE=PASS"
puts "INVITATION_DUPLICATE_GATE=PASS"
puts "INVITATION_ROLE_VALIDATION_GATE=PASS"
puts "INVITATION_EXPIRY_GATE=PASS"
puts "INVITATION_RESEND_GATE=PASS"
puts "INVITATION_REVOKE_GATE=PASS"
puts "INVITATION_AUDIT_GATE=PASS"
puts "INTEGRATION_SMOKE_TEST_GATE=PASS"
RUBY

cleanup_test_environment
echo "REQUEST_TEST_DATABASE=DISPOSABLE_POSTGRESQL"
echo "REQUEST_TEST_REDIS=DISPOSABLE_REDIS"
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

DEPLOYED=1
docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps --force-recreate manyfold

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
  (umask 022; mkdir -p "$SOURCE/$(dirname "$path")")
  rsync -a --checksum "$STAGED/$path" "$SOURCE/$path"
  cmp -s "$CHECKOUT/$path" "$SOURCE/$path"
done
chmod 0755 "$SOURCE/app/views/settings/invitations"
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
