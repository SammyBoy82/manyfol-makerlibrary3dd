#!/usr/bin/env bash
# Sync verified MakerLibrary3D v4.9.1 from DuckerHost to its GitHub release branch.
# Production is never modified. No force-push is used.
set -Eeuo pipefail
umask 077

[[ ${EUID} -eq 0 ]] || {
  echo "Run with: sudo bash ~/Sync-MakerLibrary3D-v4.9.1-to-GitHub.sh" >&2
  exit 1
}

SRC="/srv/slforge/source/manyfol-makerlibrary3dd"
REPO="SammyBoy82/manyfol-makerlibrary3dd"
REL="release/makerlibrary3d-v4.9.1"
NEXT="feature/makerlibrary3d-v4.10-membership"
TAG="makerlibrary3d-v4.9.1"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SYNC_USER="${SUDO_USER:-samadmin}"
SYNC_GROUP="$(id -gn "$SYNC_USER")"
ROOT="/srv/slforge/git-sync"
TREE="$ROOT/makerlibrary3d-v4.9.1-$STAMP"
REPORT="/tmp/MakerLibrary3D-v4.9.1-github-sync-$STAMP.txt"

as_user() {
  sudo -u "$SYNC_USER" -H "$@"
}

echo "========== MAKERLIBRARY3D GITHUB SYNC =========="

test -f "$SRC/config/routes.rb" || {
  echo "STOPPED: authoritative source is missing: $SRC"
  exit 1
}

for cmd in git gh rsync python3; do
  command -v "$cmd" >/dev/null || {
    echo "STOPPED: required command is missing: $cmd"
    exit 1
  }
done

as_user gh auth status --hostname github.com >/dev/null 2>&1 || {
  echo "STOPPED: GitHub CLI is not authenticated for $SYNC_USER."
  echo "Run: gh auth login --hostname github.com --git-protocol https --web"
  exit 1
}

as_user gh auth setup-git --hostname github.com
install -d -o "$SYNC_USER" -g "$SYNC_GROUP" -m 0750 "$ROOT"

echo
echo "========== CLONE RELEASE BRANCH =========="

as_user git clone \
  --branch "$REL" \
  --single-branch \
  "https://github.com/$REPO.git" \
  "$TREE"

echo
echo "========== OVERLAY VERIFIED SOURCE =========="

for dir in app bin config db lib public test spec vendor; do
  [ -d "$SRC/$dir" ] || continue
  install -d -o "$SYNC_USER" -g "$SYNC_GROUP" -m 0750 "$TREE/$dir"
  rsync -a --delete \
    --exclude='.git/' \
    --exclude='bundle/' \
    --exclude='cache/' \
    --exclude='node_modules/' \
    --exclude='credentials/' \
    --exclude='credentials*.yml.enc' \
    --exclude='master.key' \
    --exclude='.env*' \
    --exclude='storage/' \
    --exclude='storage-requests/' \
    --exclude='storage-status/' \
    --exclude='uploads/' \
    --exclude='assets/' \
    --exclude='packs/' \
    --exclude='vite/' \
    "$SRC/$dir/" "$TREE/$dir/"
done

for file in \
  .dockerignore .gitignore .ruby-version .tool-versions \
  Dockerfile Gemfile Gemfile.lock package.json package-lock.json \
  yarn.lock pnpm-lock.yaml Procfile Rakefile config.ru README.md \
  MAKERLIBRARY3D_PROJECT_STATE.md
do
  if [ -f "$SRC/$file" ] && [ ! -L "$SRC/$file" ]; then
    cp -a "$SRC/$file" "$TREE/$file"
  fi
done

echo
echo "========== VERSION HOST COMPONENTS =========="

OPS="$TREE/ops/makerlibrary3d"
install -d -o "$SYNC_USER" -g "$SYNC_GROUP" -m 0750 \
  "$OPS/host" "$OPS/systemd" "$OPS/compose"

for helper in \
  /usr/local/sbin/makerlibrary-storage-helper \
  /usr/local/sbin/makerlibrary-storage-health \
  /usr/local/sbin/slforge-storage-propagation
do
  [ -f "$helper" ] && install -m 0755 "$helper" "$OPS/host/"
done

for unit in \
  makerlibrary-storage-queue.path \
  makerlibrary-storage-queue.service \
  makerlibrary-storage-health.service \
  makerlibrary-storage-health.timer \
  slforge-storage-propagation.service
do
  [ -f "/etc/systemd/system/$unit" ] &&
    install -m 0644 "/etc/systemd/system/$unit" "$OPS/systemd/$unit"
done

for compose in docker-compose.storage-v4.9.yml docker-compose.v4.9.1.yml; do
  [ -f "/srv/slforge/docker/stack/$compose" ] &&
    install -m 0644 "/srv/slforge/docker/stack/$compose" "$OPS/compose/$compose"
done

cat > "$OPS/RELEASE.txt" <<'RELEASE'
MakerLibrary3D release: v4.9.1
Production image: slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.9.1
Production host: DuckerHost
Accepted UTC: 2026-09-14
Storage propagation: rshared
Azure Files validation: 15 models, 30 ModelFile records
RELEASE

chown -R "$SYNC_USER:$SYNC_GROUP" "$TREE"

echo
echo "========== PUBLIC REPOSITORY SECRET GATE =========="

python3 - "$TREE" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
bad_names = {".env", ".env.local", ".env.production", "master.key"}
patterns = {
    "private key": re.compile(rb"-----BEGIN [^-]*(?:PRIVATE|OPENSSH) KEY-----"),
    "GitHub token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"),
    "AWS key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "Azure account key": re.compile(
        rb"AccountKey=[A-Za-z0-9+/]{30,}={0,2}", re.IGNORECASE
    ),
}
problems = []

for path in root.rglob("*"):
    rel = path.relative_to(root)
    if ".git" in rel.parts or not path.is_file() or path.is_symlink():
        continue
    if path.name in bad_names or path.name.startswith(".env."):
        problems.append(f"forbidden file: {rel}")
        continue
    try:
        if path.stat().st_size > 5_000_000:
            continue
        data = path.read_bytes()
        for label, pattern in patterns.items():
            if pattern.search(data):
                problems.append(f"{label}: {rel}")
    except OSError:
        problems.append(f"unreadable file: {rel}")

if problems:
    print("STOPPED: possible secrets detected:")
    print("\n".join(f"  {item}" for item in problems))
    raise SystemExit(1)

print("SECRET_GATE=PASS")
PY

echo
echo "========== COMMIT AND PUSH RELEASE =========="

as_user git -C "$TREE" config user.name "MakerLibrary3D Release Automation"
as_user git -C "$TREE" config user.email "info@slforge.com.au"
as_user git -C "$TREE" add -A
as_user git -C "$TREE" diff --cached --check

if ! as_user git -C "$TREE" diff --cached --quiet; then
  as_user git -C "$TREE" diff --cached --stat
  as_user git -C "$TREE" commit \
    -m "Release MakerLibrary3D v4.9.1" \
    -m "Consolidate the verified production source, Storage Sources wizard, SMB and Azure Files support, activity controls and persistent mount helpers."
fi

COMMIT="$(as_user git -C "$TREE" rev-parse HEAD)"
as_user git -C "$TREE" push --set-upstream origin "$REL"

echo
echo "========== TAG AND V4.10 BRANCH =========="

if ! as_user git -C "$TREE" ls-remote --exit-code \
  --tags origin "refs/tags/$TAG" >/dev/null 2>&1
then
  as_user git -C "$TREE" tag -a "$TAG" \
    -m "MakerLibrary3D v4.9.1 production release"
  as_user git -C "$TREE" push origin "$TAG"
else
  echo "Release tag already exists; it was not changed."
fi

if ! as_user git -C "$TREE" ls-remote --exit-code \
  --heads origin "refs/heads/$NEXT" >/dev/null 2>&1
then
  as_user git -C "$TREE" checkout -b "$NEXT"
  as_user git -C "$TREE" push --set-upstream origin "$NEXT"
else
  echo "v4.10 branch already exists; it was not changed."
fi

{
  echo "repository=$REPO"
  echo "release_branch=$REL"
  echo "release_tag=$TAG"
  echo "release_commit=$COMMIT"
  echo "next_branch=$NEXT"
  echo "production_changed=false"
  echo "GITHUB_SYNC=PASS"
} | tee "$REPORT"

chown "$SYNC_USER:$SYNC_GROUP" "$REPORT"
chmod 0600 "$REPORT"

echo
echo "========== COMPLETE =========="
echo "GITHUB_SYNC=PASS"
echo "COMMIT=$COMMIT"
echo "REPORT=$REPORT"
echo "WORKTREE=$TREE"
