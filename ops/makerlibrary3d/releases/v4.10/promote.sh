#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RC_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.10-rc1"
FINAL_IMAGE="slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.10"
CONTAINER="slforge-manyfold"
STACK="/srv/slforge/docker/stack"
REPOSITORY="SammyBoy82/manyfol-makerlibrary3dd"
FEATURE_BRANCH="feature/makerlibrary3d-v4.10-membership"
RELEASE_BRANCH="release/makerlibrary3d-v4.10"
NEXT_BRANCH="feature/makerlibrary3d-v4.11-member-experience"
TAG="makerlibrary3d-v4.10"
SMTP_OVERRIDE="$STACK/docker-compose.mail-v4.10-rc1.yml"
FINAL_OVERRIDE="$STACK/docker-compose.storage-v4.10.yml"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE="/srv/slforge/releases/makerlibrary3d-v4.10-$STAMP"
REPORT="/tmp/MakerLibrary3D-v4.10-final-result-$STAMP.txt"
LOG="/tmp/MakerLibrary3D-v410-final-$STAMP.log"
BUILD_CONTAINER="makerlibrary3d-v410-promotion-$STAMP"
SYNC_USER="${SUDO_USER:-samadmin}"
DEPLOYED=0
OVERRIDE_WRITTEN=0
GITHUB_CREATED=()
GITHUB_RELEASE_CREATED=0

exec > >(tee -a "$LOG") 2>&1
die() { echo "STOPPED: $*" >&2; exit 1; }
run_user() { sudo -u "$SYNC_USER" -H "$@"; }
cleanup() { docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true; }

cleanup_github() {
  set +e
  if [ "$GITHUB_RELEASE_CREATED" -ne 0 ]; then
    run_user gh release delete "$TAG" --repo "$REPOSITORY" --yes >/dev/null 2>&1 || true
  fi
  for ref in "${GITHUB_CREATED[@]}"; do
    run_user gh api --method DELETE "repos/$REPOSITORY/git/refs/$ref" >/dev/null 2>&1 || true
  done
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
    puts({running: running, queued: queued, scheduled: scheduled, retries: retries.size, retry_classes: classes}.to_json)
    abort "Jobs are active" unless running.zero? && queued.zero? && scheduled.zero? && (classes.keys - ["Federails::NotifyInboxJob"]).empty?
    puts "JOB_GATE=PASS"
  '
}

rollback() {
  set +e
  echo "========== AUTOMATIC ROLLBACK TO RC1 =========="
  rm -f "$FINAL_OVERRIDE"
  OLD=(-p slforge)
  while IFS= read -r file; do [ -n "$file" ] && OLD+=(-f "$file"); done < "$RELEASE/compose-files.txt"
  docker compose "${OLD[@]}" up -d --no-deps --force-recreate manyfold
  for attempt in $(seq 1 36); do
    docker exec --user 1500:1500 "$CONTAINER" bin/rails runner 'puts "ROLLBACK_READY=true"' >/dev/null 2>&1 && break
    sleep 5
  done
  docker exec --user 1500:1500 "$CONTAINER" bin/rails runner 'puts "ROLLBACK_READY=true"'
  echo "ROLLBACK_OK=true"
}

failed() {
  rc=$?
  cleanup
  echo "FAILED at line $1 (exit $rc)"
  cleanup_github
  if [ "$DEPLOYED" -eq 0 ] && [ "$OVERRIDE_WRITTEN" -ne 0 ]; then
    rm -f "$FINAL_OVERRIDE"
  fi
  [ "$DEPLOYED" -eq 0 ] || rollback
  echo "LOG=$LOG"
  echo "RELEASE=$RELEASE"
  exit "$rc"
}
trap 'failed $LINENO' ERR
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "run with sudo"
for command in docker curl python3 sudo gh; do command -v "$command" >/dev/null || die "missing $command"; done

echo "LOG=$LOG"
echo "========== V4.10 FINAL PROMOTION =========="
CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
CURRENT_STATUS="$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
PROPAGATION="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/storage-sources"}}{{.Propagation}}{{end}}{{end}}')"
echo "current_image=$CURRENT_IMAGE status=$CURRENT_STATUS propagation=$PROPAGATION"
[ "$CURRENT_IMAGE" = "$RC_IMAGE" ] || die "not on verified v4.10-rc1"
[ "$CURRENT_STATUS" = "running" ] || die "Manyfold is not running"
[ "$PROPAGATION" = "rshared" ] || die "storage propagation is not rshared"
[ -f /etc/slforge-mail/smtp.env ] || die "SMTP environment is missing"
[ "$(stat -c %a /etc/slforge-mail/smtp.env)" = 600 ] || die "SMTP environment mode is not 0600"
[ -f "$SMTP_OVERRIDE" ] || die "SMTP override is missing"
[ ! -e "$FINAL_OVERRIDE" ] || die "final v4.10 override already exists; inspect the previous promotion attempt"
run_user gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub authentication missing"
REMOTE_HEAD="$(run_user gh api "repos/$REPOSITORY/git/ref/heads/$FEATURE_BRANCH" --jq .object.sha)"
echo "github_feature_head=$REMOTE_HEAD"
job_gate

docker exec --user 1500:1500 "$CONTAINER" bin/rails runner '
  abort "Invitations unavailable" unless Rails.application.routes.url_helpers.settings_invitations_path == "/settings/invitations"
  abort "SMTP unavailable" unless SiteSettings.email_configured?
  smtp = Rails.application.config.action_mailer.smtp_settings
  abort "Wrong SMTP server" unless smtp[:address] == "mail.smtp2go.com"
  abort "SMTP password missing" if smtp[:password].to_s.empty?
  puts "RC_INVITATION_SMTP_GATE=PASS"
'

install -d -m 0700 "$RELEASE"
CONFIG_LABEL="$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
python3 - "$CONFIG_LABEL" "$RELEASE/compose-files.txt" "$SMTP_OVERRIDE" <<'PY'
from pathlib import Path
import sys
paths = [Path(x.strip()).resolve() for x in sys.argv[1].split(",") if x.strip()]
smtp = Path(sys.argv[3]).resolve()
if not paths or smtp not in paths:
    raise SystemExit("SMTP override is not active")
for path in paths:
    if not path.is_file():
        raise SystemExit(f"Missing active Compose file: {path}")
Path(sys.argv[2]).write_text("\n".join(map(str, paths)) + "\n")
PY
echo "ACTIVE_COMPOSE_GATE=PASS"

echo "========== CREATE FINAL IMAGE =========="
docker image inspect "$FINAL_IMAGE" >/dev/null 2>&1 && docker image rm "$FINAL_IMAGE" >/dev/null || true
docker create --name "$BUILD_CONTAINER" "$RC_IMAGE" >/dev/null
docker commit --change "LABEL com.slforge.version=4.10" \
  --change "LABEL com.slforge.source_commit=$REMOTE_HEAD" \
  --change "LABEL com.slforge.source_branch=$RELEASE_BRANCH" \
  "$BUILD_CONTAINER" "$FINAL_IMAGE" >/dev/null
docker rm "$BUILD_CONTAINER" >/dev/null
[ "$(docker image inspect "$FINAL_IMAGE" --format '{{index .Config.Labels "com.slforge.version"}}')" = 4.10 ]
echo "FINAL_IMAGE_GATE=PASS"

cat > "$FINAL_OVERRIDE" <<YAML
services:
  manyfold:
    image: $FINAL_IMAGE
YAML
OVERRIDE_WRITTEN=1
chmod 0644 "$FINAL_OVERRIDE"
ARGS=(-p slforge)
while IFS= read -r file; do [ -n "$file" ] && ARGS+=(-f "$file"); done < "$RELEASE/compose-files.txt"
ARGS+=(-f "$FINAL_OVERRIDE")
docker compose "${ARGS[@]}" config >/dev/null
echo "COMPOSE_GATE=PASS"

cat > "$RELEASE/rollback.sh" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
rm -f "$FINAL_OVERRIDE"
OLD=(-p slforge)
while IFS= read -r file; do
  [ -n "\$file" ] && OLD+=(-f "\$file")
done < "$RELEASE/compose-files.txt"
docker compose "\${OLD[@]}" up -d --no-deps --force-recreate manyfold
for attempt in \$(seq 1 36); do
  docker exec --user 1500:1500 "$CONTAINER" bin/rails runner 'puts "ROLLBACK_READY=true"' >/dev/null 2>&1 && break
  sleep 5
done
docker exec --user 1500:1500 "$CONTAINER" bin/rails runner 'puts "ROLLBACK_READY=true"'
echo "ROLLBACK_OK=true"
ROLLBACK
chmod 0700 "$RELEASE/rollback.sh"

echo "========== DEPLOY FINAL V4.10 =========="
DEPLOYED=1
docker compose "${ARGS[@]}" up -d --no-deps --force-recreate manyfold
READY=0
for attempt in $(seq 1 36); do
  if docker exec --user 1500:1500 "$CONTAINER" bin/rails runner 'puts "RAILS_READY=true"' >/dev/null 2>&1; then READY=1; break; fi
  echo "Waiting for Manyfold startup..."
  sleep 5
done
[ "$READY" -eq 1 ] || die "Manyfold did not become ready"

docker exec --user 1500:1500 "$CONTAINER" bin/rails runner '
  helpers = Rails.application.routes.url_helpers
  abort "Invitation route missing" unless helpers.settings_invitations_path == "/settings/invitations"
  abort "Invitation controller missing" unless defined?(Settings::InvitationsController)
  abort "SMTP unavailable" unless SiteSettings.email_configured?
  smtp = Rails.application.config.action_mailer.smtp_settings
  abort "Wrong SMTP endpoint" unless smtp[:address] == "mail.smtp2go.com" && smtp[:port].to_i == 2525
  abort "SMTP password missing" if smtp[:password].to_s.empty?
  puts "INVITATION_RUNTIME_GATE=PASS"
  puts "SMTP_RUNTIME_GATE=PASS"
'
[ "$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')" = "$FINAL_IMAGE" ]
[ "$(docker inspect "$CONTAINER" --format '{{.State.Status}}')" = running ]
[ "$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/storage-sources"}}{{.Propagation}}{{end}}{{end}}')" = rshared ]
curl -fsS --max-time 30 https://library.makerlibrary3d.store/health >/dev/null
echo "HTTP_GATE=PASS"
job_gate

echo "========== GITHUB RELEASE SYNC =========="
for ref in "heads/$RELEASE_BRANCH" "tags/$TAG" "heads/$NEXT_BRANCH"; do
  if run_user gh api "repos/$REPOSITORY/git/ref/$ref" >/dev/null 2>&1; then
    die "GitHub ref already exists unexpectedly: $ref"
  fi
done
run_user gh api --method POST "repos/$REPOSITORY/git/refs" -f ref="refs/heads/$RELEASE_BRANCH" -f sha="$REMOTE_HEAD" >/dev/null
GITHUB_CREATED+=("heads/$RELEASE_BRANCH")
run_user gh api --method POST "repos/$REPOSITORY/git/refs" -f ref="refs/tags/$TAG" -f sha="$REMOTE_HEAD" >/dev/null
GITHUB_CREATED+=("tags/$TAG")
run_user gh api --method POST "repos/$REPOSITORY/git/refs" -f ref="refs/heads/$NEXT_BRANCH" -f sha="$REMOTE_HEAD" >/dev/null
GITHUB_CREATED+=("heads/$NEXT_BRANCH")
run_user gh release create "$TAG" --repo "$REPOSITORY" --title "MakerLibrary3D v4.10" \
  --notes "Membership onboarding and invitations, secure token lifecycle, role and plan assignment, SMTP2GO delivery, audit logging, and preserved v4.9.1 storage-source support." >/dev/null
GITHUB_RELEASE_CREATED=1
for ref in "heads/$RELEASE_BRANCH" "tags/$TAG" "heads/$NEXT_BRANCH"; do
  [ "$(run_user gh api "repos/$REPOSITORY/git/ref/$ref" --jq .object.sha)" = "$REMOTE_HEAD" ]
done
echo "GITHUB_SYNC_OK=true"

cat > "$REPORT" <<REPORT
MakerLibrary3D v4.10 final
promoted_utc=$STAMP
image=$FINAL_IMAGE
source_commit=$REMOTE_HEAD
release_branch=$RELEASE_BRANCH
release_tag=$TAG
next_branch=$NEXT_BRANCH
smtp_runtime_gate=pass
invitation_runtime_gate=pass
http_gate=pass
job_gate=pass
github_sync=pass
rollback=sudo bash $RELEASE/rollback.sh
REPORT
chmod 0600 "$REPORT"

DEPLOYED=0
trap - ERR
echo "========== COMPLETE =========="
echo "DEPLOYMENT_OK=true"
echo "GITHUB_SYNC_OK=true"
echo "VERSION=4.10"
echo "IMAGE=$FINAL_IMAGE"
echo "SOURCE_COMMIT=$REMOTE_HEAD"
echo "REPORT=$REPORT"
echo "RELEASE=$RELEASE"
echo "ROLLBACK=sudo bash $RELEASE/rollback.sh"
