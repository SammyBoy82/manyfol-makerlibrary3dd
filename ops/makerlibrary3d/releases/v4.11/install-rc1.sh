#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="4.11-rc1"
BASE_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.10"
TARGET_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.11-rc1"
REPOSITORY="https://github.com/SammyBoy82/manyfol-makerlibrary3dd.git"
BRANCH="feature/makerlibrary3d-v4.11-member-experience"
REQUIRED_COMMIT="a6933e210aec5b2ef9916e48a453bf9a89bfade1"
SOURCE="/srv/slforge/source/manyfol-makerlibrary3dd"
STACK="/srv/slforge/docker/stack"
CONTAINER="slforge-manyfold"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE="/srv/slforge/releases/makerlibrary3d-v4.11-rc1-$STAMP"
CHECKOUT="$RELEASE/checkout"
BACKUP="$RELEASE/backup"
STAGED="$RELEASE/staged-code"
OVERRIDE="$STACK/docker-compose.storage-v4.11-rc1.yml"
REPORT="/tmp/MakerLibrary3D-v4.11-rc1-result-$STAMP.txt"
LOG="/tmp/MakerLibrary3D-v411-rc1-$STAMP.log"
BUILD_CONTAINER="makerlibrary3d-v411-build-$STAMP"
TEST_NETWORK="makerlibrary3d-v411-test-$STAMP"
TEST_DB_CONTAINER="makerlibrary3d-v411-postgres-$STAMP"
TEST_REDIS_CONTAINER="makerlibrary3d-v411-redis-$STAMP"
TEST_DB_USER="makerlibrary_test"
TEST_DB_NAME="makerlibrary_test"
TEST_DB_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
DEPLOYED=0

RUNTIME_FILES=(
  app/controllers/home_controller.rb
  app/controllers/member_activity_controller.rb
  app/controllers/model_files_controller.rb
  app/controllers/models_controller.rb
  app/models/download_event.rb
  app/models/model_view.rb
  app/policies/member_activity_policy.rb
  app/views/application/_navbar.html.erb
  app/views/home/index.html.erb
  app/views/member_activity/downloads.html.erb
  app/views/member_activity/favorites.html.erb
  app/views/member_activity/recently_viewed.html.erb
  config/routes.rb
  db/migrate/20260926031500_create_member_activity.rb
)
SOURCE_FILES=(
  "${RUNTIME_FILES[@]}"
  ops/makerlibrary3d/releases/v4.11/README.md
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
echo "MakerLibrary3D v4.11-rc1 — installer revision 2 — accelerated member-experience release"
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

[ "$CURRENT_IMAGE" = "$BASE_IMAGE" ] || die "production is not on the verified v4.10 baseline"
[ "$CURRENT_STATUS" = "running" ] || die "Manyfold is not running"
[ "$PROPAGATION" = "rshared" ] || die "storage propagation is not rshared"

job_gate

mkdir -p "$CHECKOUT" "$BACKUP/source"
git clone --quiet --depth 50 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
HEAD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD ||
  die "the GitHub branch does not contain the reviewed v4.11 code"
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

docker cp "$STAGED/app/views/member_activity" "$BUILD_CONTAINER:/usr/src/app/app/views/"
for path in "${RUNTIME_FILES[@]}"; do
  case "$path" in
    app/views/member_activity/*) continue ;;
  esac
  docker cp "$STAGED/$path" "$BUILD_CONTAINER:/usr/src/app/$path"
done

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
  ' "${RUNTIME_FILES[@]}"


for path in "${RUNTIME_FILES[@]}"; do
  case "$path" in
    *.rb) docker run --rm --user 1500:1500 --entrypoint ruby "$TARGET_IMAGE" -c "/usr/src/app/$path" ;;
  esac
done

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

def assert_http(session, expected, label)
  return if session.response.status == expected

  body = session.response.body.to_s.gsub(/\s+/, " ")[0, 800]
  location = session.response.headers["location"]
  raise [
    "INTEGRATION_GATE_FAILED: #{label}",
    "expected=#{expected}",
    "actual=#{session.response.status}",
    "location=#{location.inspect}",
    "body=#{body.inspect}"
  ].join("; ")
end

assert_gate(Process.uid == 1500 && Process.gid == 1500, "test must run as runtime UID/GID 1500")
puts "INTEGRATION_RUNTIME_IDENTITY_GATE=PASS"

library_path = "/tmp/makerlibrary-v411-smoke-library"
FileUtils.mkdir_p(library_path)

library = Library.create!(
  name: "v4.11 Smoke Library",
  path: library_path,
  storage_service: "filesystem"
)

password = SecureRandom.base64(36)
member = User.create!(
  username: "v411_smoke_member",
  email: "v411-smoke-member@example.com",
  password: password,
  password_confirmation: password,
  approved: true,
  membership_status: "active"
)

plan = MembershipPlan.create!(
  name: "v4.11 Smoke Plan",
  description: "Disposable integration validation",
  billing_interval: "month",
  active: true,
  all_libraries: true
)
member.update!(membership_plan: plan)
assert_gate(member.is_member?, "member role was not assigned")
assert_gate(member.membership_access_active?, "member access is not active")

model = Model.create!(
  name: "v4.11 Member Model",
  path: "v411-member-model",
  library: library
)

other_model = Model.create!(
  name: "v4.11 Other Member Model",
  path: "v411-other-member-model",
  library: library
)

# Caber authorization is independent of membership-plan entitlement. Grant the
# disposable member access explicitly so the request test exercises v4.11
# activity tracking instead of depending on the installation's default role.
model.grant_permission_to("view", member)
other_model.grant_permission_to("view", member)
assert_gate(ModelPolicy.new(member, model).show?, "fixture member cannot view the primary model")
assert_gate(
  ModelPolicy::Scope.new(member, Model).resolve.exists?(model.id),
  "primary model is absent from the fixture member policy scope"
)

member.liked_list.list_items.create!(listable: model)

other_password = SecureRandom.base64(36)
other_member = User.create!(
  username: "v411_other_member",
  email: "v411-other-member@example.com",
  password: other_password,
  password_confirmation: other_password,
  approved: true,
  membership_status: "active",
  membership_plan: plan
)
DownloadEvent.record!(user: other_member, model: other_model, selection: "other-member-only")

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! "example.com"

session.post(
  "/users/sign_in",
  params: {
    user: {
      email: member.email,
      password: password
    }
  }
)
assert_gate(session.response.redirect?, "member sign-in failed")

session.get("/models/#{model.to_param}")
assert_http(session, 200, "model page did not return HTTP 200")
view = ModelView.find_by(user: member, model: model)
assert_gate(view.present?, "model view was not recorded")
assert_gate(view.view_count == 1, "first model view count is incorrect")

session.get("/models/#{model.to_param}")
assert_gate(ModelView.where(user: member, model: model).count == 1, "model view was duplicated")
assert_gate(view.reload.view_count == 2, "repeat model view was not counted")

DownloadEvent.record!(user: member, model: model, selection: "all")

session.get("/member/favorites")
assert_http(session, 200, "favorites page did not return HTTP 200")
assert_gate(session.response.body.include?(model.name), "favorite model was not shown")

session.get("/member/recently-viewed")
assert_http(session, 200, "recently viewed page did not return HTTP 200")
assert_gate(session.response.body.include?(model.name), "recently viewed model was not shown")

session.get("/member/downloads")
assert_http(session, 200, "downloads page did not return HTTP 200")
assert_gate(session.response.body.include?(model.name), "member download was not shown")
assert_gate(!session.response.body.include?(other_model.name), "another member's download was exposed")

session.get("/dashboard")
assert_http(session, 200, "member dashboard did not return HTTP 200")
assert_gate(session.response.body.include?("Favorites"), "favorites dashboard panel did not render")
assert_gate(session.response.body.include?("Recently Viewed"), "recently viewed dashboard panel did not render")
assert_gate(session.response.body.include?("My Downloads"), "downloads dashboard panel did not render")

session.delete("/member/recently-viewed")
assert_gate(session.response.redirect?, "clear recently viewed did not redirect")
assert_gate(ModelView.where(user: member).none?, "recently viewed history was not cleared")

session.delete("/member/downloads")
assert_gate(session.response.redirect?, "clear downloads did not redirect")
assert_gate(DownloadEvent.where(user: member).none?, "download history was not cleared")
assert_gate(DownloadEvent.where(user: other_member).one?, "another member's history was modified")

puts "FAVORITES_GATE=PASS"
puts "RECENTLY_VIEWED_GATE=PASS"
puts "DOWNLOAD_HISTORY_GATE=PASS"
puts "MEMBER_PRIVACY_GATE=PASS"
puts "MEMBER_HISTORY_CLEAR_GATE=PASS"
puts "MEMBER_DASHBOARD_GATE=PASS"
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

ROLLBACK_OVERRIDE="$STACK/docker-compose.rollback-v4.10.yml"
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

docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps \
  --entrypoint bin/rails manyfold db:migrate
echo "PRODUCTION_MIGRATION_GATE=PASS"

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
  abort "Favorites route missing" unless helpers.member_favorites_path == "/member/favorites"
  abort "Recently viewed route missing" unless helpers.member_recently_viewed_path == "/member/recently-viewed"
  abort "Downloads route missing" unless helpers.member_downloads_path == "/member/downloads"
  abort "Member activity controller missing" unless defined?(MemberActivityController)
  abort "ModelView table missing" unless ModelView.table_exists?
  abort "DownloadEvent table missing" unless DownloadEvent.table_exists?
  puts "MEMBER_ACTIVITY_ROUTES_GATE=PASS"
  puts "MEMBER_ACTIVITY_SCHEMA_GATE=PASS"
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
chmod 0755 "$SOURCE/app/views/member_activity"
echo "SOURCE_SYNC_GATE=PASS"

cat > "$REPORT" <<REPORT
MakerLibrary3D v4.11-rc1
accepted_utc=$STAMP
image=$TARGET_IMAGE
source_commit=$HEAD_SHA
source_branch=$BRANCH
container_status=$RUNTIME_STATUS
storage_propagation=$RUNTIME_PROPAGATION
member_activity_routes_gate=pass
member_activity_schema_gate=pass
favorites_gate=pass
recently_viewed_gate=pass
download_history_gate=pass
member_privacy_gate=pass
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
