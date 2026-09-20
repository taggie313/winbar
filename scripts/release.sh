#!/usr/bin/env bash
# Cut a Winbar release: build, sign, notarize, staple, wrap in a disk image,
# and point the Homebrew cask at it.
#
#   scripts/release.sh 0.1.0 --dry-run   build + sign + build the DMG, then stop and say what is next
#   scripts/release.sh 0.1.0             ...+ notarize, staple, tag, prepare the tap's cask,
#                                        then print the exact commands that publish it
#   scripts/release.sh 0.1.0 --publish   ...and run those commands: push the tag, create the
#                                        GitHub release, push the tap
#
# ONE artifact, two ways to install it. A DMG holding Winbar.app beside a
# symlink to /Applications is the whole release: someone who has never heard of
# Homebrew downloads it and drags one icon onto the other, and Homebrew's cask
# downloads and mounts that same file. A zip would serve the second audience
# and leave the first with a Downloads folder full of loose app.
#
# Why Developer ID + notarization on both: a cask, unlike a formula, keeps
# macOS's quarantine attribute on what it downloads, and so does Safari, so
# Gatekeeper assesses what comes out either way. Anything not Developer
# ID-signed AND notarized gets the "cannot be opened" wall, which is exactly
# the wrong first impression for people who are not experts.
#
# Why BOTH the app and the DMG are stapled, in that order:
#   * the app is notarized and stapled first, so the copy dragged to
#     /Applications carries its own ticket and passes Gatekeeper with no
#     network. A ticket stapled to the DMG does not travel with the app out of
#     it.
#   * the DMG is then built from that stapled app, signed, notarized and
#     stapled itself, so double-clicking the download doesn't need the network
#     either.
# Stapling the DMG last is not optional: it is a different file from the one
# Apple saw when it notarized the app, so it needs a ticket of its own.
#
# Why the default run stops short of publishing: everything it does is local
# and can be thrown away (the commands to do that are printed), and it leaves
# even the tap checkout alone — the cask is prepared under dist/ and copied in
# only when the release it points at exists. A pushed tag, a GitHub release and
# a pushed tap commit cannot be taken back, so they take an explicit --publish.
#
# One-time setup on the release Mac:
#   * a "Developer ID Application" certificate in the login keychain
#   * a notarytool keychain profile, so the Apple ID password lives in the
#     keychain and never in this script, a shell history or the repo:
#         xcrun notarytool store-credentials winbar --apple-id <id> --team-id <team>
#     (it prompts for an app-specific password from account.apple.com)
#   * gh auth login
#   * brew tap taggie313/tap   (the checkout this script commits the cask to)
#   * a git remote pointing at github.com/taggie313/winbar
#
# Overrides (environment):
#   WINBAR_SIGN_IDENTITY   identity name or SHA-1, if you have more than one Developer ID
#   WINBAR_NOTARY_PROFILE  notarytool keychain profile (default: winbar)
#   WINBAR_GIT_REMOTE      git remote for github.com/taggie313/winbar (default: found by URL)
#
# Written for the bash 3.2 that ships with macOS: no associative arrays, no
# ${var,,}, and a possibly-empty array is expanded as ${a[@]+"${a[@]}"},
# because 3.2 calls a bare "${a[@]}" of an empty array unbound under set -u.
#
# The disk image is made with hdiutil, which is on every Mac. macOS 27 prints
# "'hdiutil create ...' is deprecated. Please use 'diskutil image create ...'"
# for create, convert, attach, detach and imageinfo alike — a warning on
# stderr, not a refusal: all of them still work here (checked on macOS 27.0,
# build 26A428). `diskutil image create/attach/info` is the replacement and is
# present here, but it arrived with the same release that started deprecating
# hdiutil, and this script has to keep working on the older Macs the cask
# itself supports. So: hdiutil, and the deprecation lines are filtered out of
# the output rather than silenced, so a real error still shows.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REPO=taggie313/winbar
TAP_NAME=taggie313/tap
BUNDLE_ID=net.elusive.winbar
APP=dist/Winbar.app
EXE="$APP/Contents/MacOS/Winbar"
ENTITLEMENTS=Resources/Winbar.entitlements
TEMPLATE=Casks/winbar.rb
MIN_MACOS_MAJOR=14 # must match `depends_on macos: :sonoma` in the cask
PROFILE="${WINBAR_NOTARY_PROFILE:-winbar}"

# ---------------------------------------------------------------- helpers ---

STEP=0
step()   { STEP=$((STEP + 1)); printf '\n==> %d. %s\n' "$STEP" "$*"; }
info()   { printf '    %s\n' "$*"; }
ok()     { printf '    ✓ %s\n' "$*"; }
warn()   { printf '    ! %s\n' "$*" >&2; }
indent() { sed 's/^/      /'; }

# die HEADLINE [DETAIL...]: the headline, then each detail line indented
# (usually the command that fixes it).
die() {
  printf '\n    ✗ %s\n' "$1" >&2
  [ $# -lt 2 ] || printf '%s\n' "${@:2}" | indent >&2
  exit 1
}

# A dry run exists to exercise build and signing before a real release, so it
# only insists on what it actually uses. Everything a real release needs is
# still checked and reported, so a missing notary profile shows up now, not
# after a build and a wait.
needed_for_release() {
  if [ "$DRY_RUN" = 1 ]; then
    warn "$1"
    [ $# -lt 2 ] || printf '%s\n' "${@:2}" | indent >&2
    warn "(fine for --dry-run; a real release stops here)"
    return 0
  fi
  die "$@"
}

usage() {
  cat <<EOS
usage: scripts/release.sh VERSION [--dry-run | --publish]

  VERSION     must equal the VERSION file, e.g. 0.1.0
  --dry-run   build, sign and build the disk image, then stop before notarization
  --publish   also push the tag, create the GitHub release and push the tap
EOS
}

# The CHANGELOG.md section for one version: the lines under "## [VERSION]"
# (or "## VERSION") up to the next "## " heading, minus Keep a Changelog's
# link definitions, single-line <!-- maintainer notes -->, and any leading or
# trailing blank lines. Links in it should be absolute: relative ones break on
# the release page.
changelog_section() {
  [ -f CHANGELOG.md ] || return 0
  awk -v v="$1" '
    /^## / {
      if (found) exit
      if (index($0, "## [" v "]") == 1 || $2 == v) { found = 1 }
      next
    }
    !found { next }
    /^\[[^]]+\]: / { next }
    /^[[:space:]]*<!--.*-->[[:space:]]*$/ { next }
    /^[[:space:]]*$/ && n > 0 && line[n] ~ /^[[:space:]]*$/ { next }
    { line[++n] = $0 }
    END {
      first = 1; while (first <= n && line[first] ~ /^[[:space:]]*$/) first++
      last = n;  while (last >= first && line[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print line[i]
    }
  ' CHANGELOG.md
}

plist_get() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# hdiutil, quiet on success, and with macOS 27's "'hdiutil create ...' is
# deprecated. Please use 'diskutil image create ...'" line dropped from a
# failure's output. Only that line: everything else hdiutil says is a real
# complaint and is shown. Returns hdiutil's own status, so a caller still
# decides what a failure means.
hdi() {
  local out
  out="$(hdiutil "$@" 2>&1)" && return 0
  printf '%s\n' "$out" | grep -v "deprecated. Please use 'diskutil" | indent >&2 || true
  return 1
}

# Mounted disk images this run is responsible for, so the EXIT trap can put
# them away even after a failure. bash 3.2: a plain string, one path per line.
MOUNTED=""
unmount_all() {
  [ -n "$MOUNTED" ] || return 0
  printf '%s\n' "$MOUNTED" | while IFS= read -r point; do
    [ -n "$point" ] || continue
    # -force because a Finder or Spotlight peek at a just-mounted volume is
    # enough to make a polite detach fail.
    hdiutil detach "$point" -quiet >/dev/null 2>&1 || hdiutil detach "$point" -force -quiet >/dev/null 2>&1 || true
  done
  MOUNTED=""
}

# mount_dmg IMAGE MOUNTPOINT: read-only, not in Finder's sidebar, and recorded
# for the trap. -readonly so nothing this script does can change the bytes that
# were notarized.
mount_dmg() {
  mkdir -p "$2"
  hdi attach "$1" -mountpoint "$2" -nobrowse -readonly -quiet
  MOUNTED="$MOUNTED
$2"
}

unmount_dmg() {
  hdiutil detach "$1" -quiet >/dev/null 2>&1 || hdiutil detach "$1" -force -quiet >/dev/null 2>&1
  MOUNTED="$(printf '%s\n' "$MOUNTED" | grep -vxF "$1" || true)"
}

# ------------------------------------------------------------- arguments ---

VERSION=""
DRY_RUN=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" ;;
    *)
      [ -z "$VERSION" ] || { usage >&2; die "only one VERSION, please (got '$VERSION' and '$arg')"; }
      VERSION="$arg"
      ;;
  esac
done
[ -n "$VERSION" ] || { usage >&2; exit 1; }
[ "$DRY_RUN$PUBLISH" != 11 ] || die "--dry-run and --publish contradict each other; pick one"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
  || die "'$VERSION' doesn't look like a version (expected e.g. 0.1.0 or 0.2.0-beta.1)"

TAG="v$VERSION"
DMG="dist/Winbar-$VERSION.dmg"
# What Finder puts in the window's title bar and in /Volumes while the image is
# open. The version is in it so two mounted downloads can't collide, and it is
# well inside HFS+'s 27-character volume name limit.
VOLNAME="Winbar $VERSION"
NOTES_FILE="dist/release-notes-$VERSION.md"
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/Winbar-$VERSION.dmg"

WORK="$(mktemp -d)"
trap 'unmount_all; rm -rf "$WORK"' EXIT

if [ "$DRY_RUN" = 1 ]; then
  echo "Winbar $VERSION: DRY RUN (build, sign and build the disk image only)"
elif [ "$PUBLISH" = 1 ]; then
  echo "Winbar $VERSION: full release, publishing at the end"
else
  echo "Winbar $VERSION: release, stopping before anything is pushed"
fi

# ---------------------------------------------------------- preconditions ---

step "Checking preconditions"

for tool in git codesign spctl ditto hdiutil shasum xcrun security plutil lipo vtool file awk; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "'$tool' not found; install the Command Line Tools:" "xcode-select --install"
done
for tool in gh brew curl; do
  command -v "$tool" >/dev/null 2>&1 || needed_for_release "'$tool' not found" "brew install $tool"
done

for f in VERSION scripts/build-app.sh "$ENTITLEMENTS" "$TEMPLATE"; do
  [ -e "$f" ] || die "$f is missing; is this the winbar repo?"
done
[ -x scripts/build-app.sh ] || die "scripts/build-app.sh is not executable" "chmod +x scripts/build-app.sh"

# The VERSION file is what build-app.sh stamps into Info.plist, so the app,
# the tag, the disk image's name and the cask can never disagree about what
# they are.
DECLARED="$(tr -d '[:space:]' <VERSION)"
[ "$DECLARED" = "$VERSION" ] \
  || die "VERSION says '$DECLARED' but you asked for '$VERSION'. Edit VERSION and commit first."
ok "VERSION file says $VERSION"

# Clean tree, untracked files included: the build compiles whatever is in
# Sources/, so a stray uncommitted file would ship in a release whose tag
# doesn't contain it.
git rev-parse --verify -q HEAD >/dev/null || needed_for_release "this repo has no commits yet"
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
  needed_for_release "the working tree is not clean; commit or stash first:" "$DIRTY"
else
  ok "working tree clean"
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$BRANCH" ]; then
  needed_for_release "HEAD is detached; check out the branch you are releasing from"
elif [ "$BRANCH" != main ]; then
  warn "releasing from branch '$BRANCH', not main"
fi

# The GitHub remote is found by URL rather than by name, because the repo may
# also have a Gitea remote called origin.
REMOTE="${WINBAR_GIT_REMOTE:-}"
if [ -z "$REMOTE" ]; then
  for r in $(git remote); do
    case "$(git remote get-url "$r")" in
      *github.com:$REPO | *github.com:$REPO.git | *github.com/$REPO | *github.com/$REPO.git)
        REMOTE="$r"
        break
        ;;
    esac
  done
fi
if [ -z "$REMOTE" ]; then
  needed_for_release "no git remote points at github.com/$REPO; add one (or set WINBAR_GIT_REMOTE):" \
    "git remote add github git@github.com:$REPO.git"
else
  ok "GitHub remote: $REMOTE ($(git remote get-url "$REMOTE"))"
fi

# What may reach GitHub. This repo publishes a scrubbed single commit rather than its real
# history: `public` carries main's TREE with none of main's COMMITS, because those name the
# author's VM, its UUID and his saved-PC id (docs/internal/PUBLISHING.md). So both the push and
# the tag must refer to `public` — pushing or tagging HEAD would publish all of it.
#
# This is not hypothetical. For 0.1.0 this script tagged HEAD and printed `git push github main`;
# the tag had to be moved by hand and only the local pre-push hook stopped the push. A hook is a
# backstop, not a procedure — it isn't cloned, and it can't be there on someone else's machine.
PUSH_SPEC="$BRANCH"
TAG_AT="HEAD"
if git rev-parse -q --verify refs/heads/public >/dev/null; then
  PUSH_SPEC="public:$BRANCH"
  TAG_AT="public"
  if [ "$(git rev-parse public^{tree})" != "$(git rev-parse HEAD^{tree})" ]; then
    needed_for_release "'public' doesn't hold the tree you are releasing, so the tag and the push" \
      "would publish source that isn't what this build was made from. Rebuild it first" \
      "(docs/internal/PUBLISHING.md step 3)."
  else
    ok "publishing 'public' as $BRANCH (same tree as HEAD, without its history)"
  fi
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  needed_for_release "tag $TAG already exists locally; if it is left over from an abandoned run:" \
    "git tag -d $TAG"
elif [ -n "$REMOTE" ] && git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  needed_for_release "tag $TAG already exists on $REMOTE; bump VERSION rather than re-release"
else
  ok "tag $TAG is free"
fi

# Signing identity. With exactly one Developer ID Application identity it is
# used by its SHA-1, which stays unambiguous even when an expired certificate
# with the same name is still in the keychain.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -n "${WINBAR_SIGN_IDENTITY:-}" ]; then
  grep -qF -- "$WINBAR_SIGN_IDENTITY" <<<"$IDENTITIES" \
    || die "WINBAR_SIGN_IDENTITY='$WINBAR_SIGN_IDENTITY' is not a valid signing identity here; these are:" \
      "security find-identity -v -p codesigning"
  IDENTITY="$WINBAR_SIGN_IDENTITY"
else
  DEVIDS="$(grep '"Developer ID Application: ' <<<"$IDENTITIES" || true)"
  COUNT="$(grep -c . <<<"$DEVIDS" || true)"
  case "$COUNT" in
    0)
      die "no 'Developer ID Application' signing identity in your keychain." \
        "Create one at developer.apple.com > Certificates (type: Developer ID Application)," \
        "download it, double-click it to add it to the login keychain, and re-run."
      ;;
    1) IDENTITY="$(awk '{print $2}' <<<"$DEVIDS")" ;;
    *) die "several Developer ID Application identities; set WINBAR_SIGN_IDENTITY to one SHA-1:" "$DEVIDS" ;;
  esac
fi
IDENTITY_NAME="$(grep -F -- "$IDENTITY" <<<"$IDENTITIES" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')"
case "$IDENTITY_NAME" in
  "Developer ID Application: "*) ;;
  *) die "'${IDENTITY_NAME:-$IDENTITY}' is not a Developer ID Application identity, and Apple notarizes only those" ;;
esac
TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY_NAME")"
ok "signing as $IDENTITY_NAME"

# `notarytool history` is the cheapest call that proves the stored credential
# still works; it is also the one that fails once the app-specific password
# has been revoked.
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "notarytool profile '$PROFILE' works"
else
  needed_for_release "notarytool can't read keychain profile '$PROFILE'. If you created it already, the Mac is" \
    "probably locked: notarytool keeps these in the data-protection keychain, which is unavailable" \
    "until someone unlocks the Mac (the error says 'no Keychain password item found' either way)." \
    "Otherwise create it once with:" \
    "xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id ${TEAM_ID:-<team>}" \
    "(it prompts for an app-specific password: account.apple.com > Sign-In and Security)"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh repo view "$REPO" >/dev/null 2>&1; then
    ok "gh is logged in and can see $REPO"
  else
    needed_for_release "gh can't see github.com/$REPO; create the repository first (public, MIT)"
  fi
else
  needed_for_release "gh is not logged in to GitHub:" "gh auth login"
fi

NOTES="$(changelog_section "$VERSION")"
if [ -z "$NOTES" ]; then
  needed_for_release "CHANGELOG.md has no '## [$VERSION]' section (it becomes the release notes)"
else
  ok "CHANGELOG.md has a $VERSION section"
fi

TAP=""
if command -v brew >/dev/null 2>&1; then
  TAP="$(brew --repository "$TAP_NAME")"
  if [ ! -d "$TAP/.git" ]; then
    needed_for_release "the tap isn't checked out at $TAP:" "brew tap $TAP_NAME"
  elif [ -n "$(git -C "$TAP" status --porcelain)" ]; then
    # The tap commit must contain the cask change and nothing else.
    needed_for_release "the tap checkout has uncommitted changes:" "$(git -C "$TAP" status --porcelain)"
  else
    # Behind its upstream would get the final push rejected after the tap
    # commit is already made. Skipped on a dry run, which leaves the tap
    # entirely alone, remote-tracking refs included.
    if [ "$DRY_RUN" = 0 ] && git -C "$TAP" fetch --quiet 2>/dev/null; then
      BEHIND="$(git -C "$TAP" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)"
      [ "$BEHIND" = 0 ] \
        || needed_for_release "the tap is $BEHIND commit(s) behind its upstream:" "git -C \"$TAP\" pull --ff-only"
    fi
    ok "tap checkout: $TAP"
  fi
fi

# ------------------------------------------------------------------ build ---

step "Building $APP"
# Removed first so a stale app or disk image from an earlier version can never
# be picked up if the build fails part-way.
rm -rf "$APP" "$DMG"
./scripts/build-app.sh
[ -x "$EXE" ] || die "build-app.sh finished but $EXE is missing"

# Cheap consistency checks on what was actually built, so the disk image, the
# cask and the app can't disagree.
[ "$(plist_get CFBundleIdentifier)" = "$BUNDLE_ID" ] \
  || die "Info.plist says CFBundleIdentifier '$(plist_get CFBundleIdentifier)', expected $BUNDLE_ID"
[ "$(plist_get CFBundleShortVersionString)" = "$VERSION" ] \
  || die "the app calls itself '$(plist_get CFBundleShortVersionString)', not $VERSION." \
    "build-app.sh should stamp the VERSION file into CFBundleShortVersionString."
ARCHS="$(lipo -archs "$EXE")"
case " $ARCHS " in
  *" arm64 "*) ;;
  *) die "$EXE has no arm64 slice (archs: $ARCHS)" ;;
esac
# The cask promises Sonoma. A binary with a newer deployment target would
# install fine and then refuse to launch there, so refuse it here instead.
MINOS="$(vtool -show-build "$EXE" 2>/dev/null | awk '$1 == "minos" {print $2; exit}')"
if [ -n "$MINOS" ] && [ "${MINOS%%.*}" -gt "$MIN_MACOS_MAJOR" ]; then
  die "$EXE needs macOS $MINOS, but the cask says $MIN_MACOS_MAJOR or newer; fix the deployment target or the cask"
fi
# One executable is the whole app. Nested code would have to be signed
# inside-out before the bundle, and signing with `codesign --deep` is what
# Apple explicitly says not to do, so rather than half-handle it, stop.
NESTED="$(find "$APP/Contents" -type f ! -path "$EXE" -exec file {} + | grep 'Mach-O' || true)"
[ -z "$NESTED" ] || die "unexpected nested code in the bundle; it must be signed inside-out first:" "$NESTED"
# A build that rewrites tracked files would leave the tag pointing at
# something other than what was built.
CHANGED="$(git status --porcelain --untracked-files=no)"
[ -z "$CHANGED" ] || needed_for_release "the build modified tracked files:" "$CHANGED"
ok "$BUNDLE_ID $VERSION, $ARCHS, minimum macOS ${MINOS:-unknown}"

# ------------------------------------------------------------------- sign ---

step "Signing $APP for distribution"
# build-app.sh signs for local use. Distribution needs three things on top,
# and --force replaces its signature with one that has them:
#   --options runtime  the hardened runtime; notarization rejects anything without it
#   --timestamp        a secure timestamp from Apple; also required by notarization
#   --entitlements     the hardened runtime blocks sending Apple Events unless
#                      com.apple.security.automation.apple-events is granted, and
#                      Winbar drives UTM through Apple Events
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

# --deep here only *verifies* nested code; it is signing with --deep that is
# discouraged.
VERIFY="$(codesign --verify --strict --deep --verbose=2 "$APP" 2>&1)" \
  || die "codesign --verify failed:" "$VERIFY"
SIG="$(codesign -dvv "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$SIG" || die "the signature lacks the hardened runtime flag"
grep -q '^Timestamp=' <<<"$SIG" || die "the signature has no secure timestamp (was Apple's timestamp server reachable?)"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
grep -q 'com.apple.security.automation.apple-events' <<<"$ENTS" \
  || die "the signed app lacks com.apple.security.automation.apple-events; check $ENTITLEMENTS"
ok "valid, hardened runtime, timestamped, apple-events entitlement present"

# Gatekeeper is EXPECTED to reject the app at this point: it accepts a
# Developer ID app only once Apple has notarized it, so the normal answer here
# is "rejected, source=Unnotarized Developer ID". It runs anyway because any
# other reason (say, "no usable signature") means signing is wrong, which is
# cheaper to find out now than after a round trip to Apple.
ASSESS="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
printf '%s\n' "$ASSESS" | indent
case "$ASSESS" in
  *"Unnotarized Developer ID"*) ok "rejected as unnotarized, which is expected before notarization" ;;
  *accepted*) ok "already accepted (Apple already holds a ticket for this exact code)" ;;
  *) warn "rejected for an unexpected reason; notarization will probably fail too" ;;
esac

# --------------------------------------------------------- the disk image ---

# Builds $DMG out of whatever state $APP is in right now: Winbar.app beside a
# symlink to /Applications, read-only and compressed. Called twice in a real
# release's life — once here on a dry run, once after stapling.
build_dmg() {
  local stage="$WORK/dmg"
  rm -rf "$stage" "$DMG"
  mkdir -p "$stage"
  # ditto, not cp -R: it is the copy that keeps the extended attributes, the
  # symlinks and the resource forks a signed bundle's seal covers. A stapled
  # ticket rides along with them.
  ditto "$APP" "$stage/Winbar.app"
  # The drag target, and the whole reason this is a disk image rather than a
  # zip: both icons are in the one window, and dragging the app onto the folder
  # installs it. A symlink costs nothing in the image and Finder draws it as
  # the real folder. Nothing here arranges that window — no background, no icon
  # positions, no set size. That would mean building the image read/write,
  # mounting it, scripting Finder into writing a .DS_Store and converting it
  # back; this image has no .DS_Store, so Finder opens the volume in whatever
  # view the person already uses.
  ln -s /Applications "$stage/Applications"
  # One hdiutil call does the lot: -srcfolder sizes the image from the folder,
  # UDZO is the read-only zlib-compressed format (that is what makes it
  # read-only and compressed — there is no separate flag), and zlib-level=9
  # spends a few seconds of the release on a smaller download. HFS+ because an
  # APFS image needs a newer macOS to mount than the app needs to run, and this
  # has to open on every Mac the cask claims to support.
  hdi create -volname "$VOLNAME" -srcfolder "$stage" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" \
    || die "hdiutil couldn't build $DMG"
  rm -rf "$stage"
}

# check_dmg NOTARIZED: mounts $DMG the way a user's Mac will, checks what is in
# it, shows Gatekeeper's verdict, and unmounts. With NOTARIZED=1 a missing
# ticket or a Gatekeeper rejection is fatal; with 0 it only reports, because
# before notarization a rejection is the expected answer.
check_dmg() {
  local notarized="$1" mount="$WORK/mnt" app extra verify validate assess
  mount_dmg "$DMG" "$mount"
  app="$mount/Winbar.app"

  # Layout, from the point of view of someone who just double-clicked it.
  [ -d "$app" ] || die "$DMG has no Winbar.app at the top level of its volume"
  [ -L "$mount/Applications" ] || die "$DMG has no Applications symlink to drag the app onto"
  [ "$(readlink "$mount/Applications")" = /Applications ] \
    || die "the Applications symlink points at $(readlink "$mount/Applications"), not /Applications"
  # Anything else would be clutter in the window someone opens. Dot files
  # (.fseventsd, .Trashes) are macOS's own and are invisible there.
  extra="$(ls "$mount" | grep -v '^Winbar.app$' | grep -v '^Applications$' || true)"
  [ -z "$extra" ] || warn "the volume also holds: $(echo "$extra" | tr '\n' ' ')"
  ok "volume “$VOLNAME”: Winbar.app + Applications ->/Applications"

  # The app inside the image, not the one in dist/: these are the bytes that
  # ship.
  verify="$(codesign --verify --strict --deep "$app" 2>&1)" \
    || die "the app inside $DMG fails codesign --verify:" "$verify"
  validate="$(xcrun stapler validate "$app" 2>&1 || true)"
  case "$validate" in
    *worked*) ok "the app inside carries its own stapled ticket" ;;
    *)
      [ "$notarized" = 0 ] || die "the app inside $DMG has no valid stapled ticket:" "$validate"
      info "the app inside has no ticket yet (expected before notarization)"
      ;;
  esac

  # Two assessments, because macOS makes two different decisions. `--type open`
  # with the primary-signature context is the one Gatekeeper makes when the
  # download is double-clicked; `--type execute` is the one it makes when the
  # copy in /Applications is launched.
  assess="$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
  info "spctl --assess --type open (the disk image):"
  printf '%s\n' "$assess" | indent
  if [ "$notarized" = 1 ]; then
    grep -q 'accepted' <<<"$assess" || die "Gatekeeper rejects the notarized disk image:" "$assess"
    grep -q 'Notarized Developer ID' <<<"$assess" \
      || warn "the image was accepted, but not as 'Notarized Developer ID'; read the output above before publishing"
  fi

  assess="$(spctl --assess --type execute -vv "$app" 2>&1 || true)"
  info "spctl --assess --type execute (the app inside):"
  printf '%s\n' "$assess" | indent
  if [ "$notarized" = 1 ]; then
    grep -q 'accepted' <<<"$assess" || die "Gatekeeper rejects the notarized app inside the image:" "$assess"
    grep -q 'Notarized Developer ID' <<<"$assess" \
      || warn "the app was accepted, but not as 'Notarized Developer ID'; read the output above before publishing"
  fi

  unmount_dmg "$mount"
}

# sign_dmg: a disk image is signed like any other file. Without this, the
# `--type open` assessment above has no signature to look at, and Safari's
# "downloaded from the internet" dialog has no developer name to show.
# No --options runtime and no entitlements: those describe a running process,
# and this is a container.
#
# --identifier because codesign otherwise names the image after its file up to
# the first dot, which for Winbar-0.1.0.dmg is the meaningless "Winbar-0".
sign_dmg() {
  codesign --force --timestamp --identifier "$BUNDLE_ID.dmg" --sign "$IDENTITY" "$DMG" \
    || die "couldn't sign $DMG"
  codesign --verify --strict "$DMG" || die "$DMG fails codesign --verify after signing"
}

step "Building $DMG"
# Built here even on a real release, where it is thrown away and built again
# from the stapled app a few steps down. Two seconds of hdiutil is a cheap way
# to find out that the image or its layout is wrong before a round trip to
# Apple, which is the same reason the signature is assessed above.
build_dmg
sign_dmg
ok "$DMG  $(du -h "$DMG" | cut -f1)"

step "Looking inside $DMG"
check_dmg 0

if [ "$DRY_RUN" = 1 ]; then
  cat <<EOS

Dry run complete. $APP is signed but NOT notarized, and $DMG holds
that unnotarized app (sha256 $(sha256_of "$DMG")). Don't hand it to anyone:
Gatekeeper will refuse it on any Mac but this one.

A real run (scripts/release.sh $VERSION) would continue with:
  1. xcrun notarytool submit <a zip of $APP> --keychain-profile $PROFILE --wait
     (the zip is a transport for Apple only, and is thrown away; and
     \`xcrun notarytool log <id>\` is printed if Apple rejects it)
  2. xcrun stapler staple $APP
  3. rebuild $DMG from the stapled app, sign it, notarize THAT, and staple it
     too, so the download and the installed app each pass Gatekeeper offline
  4. mount it again: stapler validate, and spctl --assess must now say
     "Notarized Developer ID" for both the image and the app inside
  5. git tag -a $TAG, and write $NOTES_FILE from CHANGELOG.md
  6. prepare $TAP_NAME's Casks/winbar.rb with version $VERSION and the disk
     image's sha256, brew style it and show the diff — the tap checkout itself
     is left alone
  7. with --publish: push $TAG, gh release create $TAG on $REPO, check the
     uploaded asset's sha256, then commit the cask in the tap and push it
EOS
  exit 0
fi

# -------------------------------------------------------------- notarize ---

# notarize PATH: submits one file and waits for Apple's verdict. Anything but
# "Accepted" ends the release, with Apple's own log if there is one.
notarize() {
  local what="$1" out json id status
  out="$(xcrun notarytool submit "$what" --keychain-profile "$PROFILE" \
    --wait --output-format json 2>"$WORK/notary.err" || true)"
  # JSON so the verdict is read from a field instead of scraped from prose. The
  # status decides, not the exit code: an "Invalid" verdict is a completed
  # submission as far as notarytool's exit code is concerned.
  json="$(grep '^{' <<<"$out" | tail -1 || true)"
  id="$(plutil -extract id raw -o - - <<<"$json" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<<"$json" 2>/dev/null || true)"
  if [ "$status" != Accepted ]; then
    warn "notarization status for $what: ${status:-no answer}"
    if [ -s "$WORK/notary.err" ]; then indent <"$WORK/notary.err" >&2; fi
    if [ -n "$id" ]; then
      # The log names each offending file and why, which is the only useful
      # part of a rejection.
      warn "Apple's log for submission $id:"
      xcrun notarytool log "$id" --keychain-profile "$PROFILE" 2>&1 | indent >&2 || true
    fi
    die "$what was not notarized, so nothing was tagged, committed or published"
  fi
  ok "accepted (submission $id)"
}

# staple PATH: stapling races Apple's CDN. --wait returns as soon as the
# submission is Accepted, but the ticket can take a little longer to become
# fetchable, and stapling before then fails with "Record not found", which
# looks alarming and means nothing. Retry rather than make it a manual step
# (learned on untofu's installer package).
staple() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if xcrun stapler staple "$1" >/dev/null 2>&1; then
      ok "stapled $1 (attempt $attempt)"
      return 0
    fi
    [ "$attempt" != 6 ] || die "the ticket for $1 never became available; nothing was tagged or committed. Re-run later."
    sleep 20
  done
}

step "Notarizing the app (usually a few minutes; Ctrl-C is safe, Apple carries on regardless)"
# Apple takes a zip, a disk image or an installer package, never a bare
# bundle, so the app goes up inside a zip. That zip is a transport and nothing
# else: it lives in the temp dir, is never published, and a zip could not carry
# the ticket back anyway.
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"

step "Stapling the ticket into $APP"
# The app is stapled BEFORE the image is built, so the copy that ends up in
# /Applications carries its own ticket and is assessed offline. A ticket on the
# image alone would be left behind the moment the app is dragged out of it.
staple "$APP"

step "Rebuilding $DMG around the stapled app"
build_dmg
sign_dmg
ok "$DMG  $(du -h "$DMG" | cut -f1)"

step "Notarizing the disk image itself"
# A second submission, not a formality: this is a different file from the zip
# Apple saw, so it needs its own ticket for the first double-click to pass
# without the network. Apple re-checks the app inside at the same time.
notarize "$DMG"
staple "$DMG"

step "Verifying the shipped disk image the way a user's Mac will see it"
check_dmg 1

SHA="$(sha256_of "$DMG")"
ok "$DMG  $(du -h "$DMG" | cut -f1)  sha256 $SHA"

# ------------------------------------------------------------ tag + notes ---

step "Tagging $TAG and writing the release notes"
git tag -a "$TAG" "$TAG_AT" -m "Winbar $VERSION"
ok "tagged $TAG at $(git rev-parse --short "$TAG_AT")$([ "$TAG_AT" = HEAD ] || echo " ($TAG_AT)")"

# Written to dist/ rather than the temp dir so the printed `gh release create`
# still works after this script has exited.
{
  printf '%s\n\n' "$NOTES"
  cat <<EOS
## Install

Download **Winbar-$VERSION.dmg** below, open it, and drag Winbar to
Applications. Then open Winbar once from Applications.

Or, with Homebrew:

\`\`\`sh
brew install --cask $TAP_NAME/winbar
\`\`\`

Either way, Winbar needs UTM and Windows App (App Store copies are fine):

\`\`\`sh
brew install --cask utm windows-app   # unless you already have them
winbar setup
\`\`\`

\`Winbar-$VERSION.dmg\` and the app inside it are both Developer ID signed and
notarized by Apple, each with its own stapled ticket, so macOS accepts them
without asking the network. sha256 \`$SHA\`
EOS
} >"$NOTES_FILE"
ok "$NOTES_FILE"

# --------------------------------------------------------------------- tap ---

# Prepared here, committed into the tap only on the publishing path, after the
# uploaded asset's sha256 has been checked. A default run used to commit
# straight into the live tap checkout, which left it one commit ahead of origin
# holding a cask whose url 404s: `brew install --cask taggie313/tap/winbar`
# fails on this Mac, `brew update` sees a diverged tap, and a stray push
# publishes a release that does not exist. The window was open until somebody
# remembered to reset it. Now a default run leaves the tap untouched and prints
# what to do; --publish does the copy, the commit and the push in one place.
step "Preparing the cask for the tap"
[ -n "$TAP" ] || die "Homebrew isn't installed, so there is no tap checkout to put the cask in"
CASK="$TAP/Casks/winbar.rb"            # where it will land, eventually
CASK_NEW="dist/cask/Casks/winbar.rb"   # what will land there. Under dist/, so
                                       # the printed commands still work after
                                       # this script exits, and in a Casks/
                                       # directory under its real name, which
                                       # is what `brew style` expects to see.
rm -rf dist/cask
mkdir -p dist/cask/Casks
if [ ! -f "$CASK" ]; then
  cp "$TEMPLATE" "$CASK_NEW"
  info "the tap has no Casks/winbar.rb yet; this one starts from $TEMPLATE"
else
  cp "$CASK" "$CASK_NEW"
fi
if [ -f "$CASK" ] && ! diff -q <(grep -vE '^  (version|sha256) ' "$TEMPLATE") \
  <(grep -vE '^  (version|sha256) ' "$CASK") >/dev/null; then
  # Only version and sha256 are rewritten. Anything else that differs is
  # shown, so a change to the template doesn't silently never reach users,
  # and a fix made directly in the tap doesn't get lost later either.
  warn "the tap's cask differs from $TEMPLATE beyond version/sha256 (the tap's text is kept):"
  diff -u --label "tap: Casks/winbar.rb" --label "template: $TEMPLATE" \
    <(grep -vE '^  (version|sha256) ' "$CASK") \
    <(grep -vE '^  (version|sha256) ' "$TEMPLATE") | indent >&2 || true
  warn "to adopt the template instead: cp $TEMPLATE \"$CASK\", then run this again"
fi
# BSD sed. Anchored to the two-space stanza indent, so a comment that happens
# to mention version or sha256 is never touched.
sed -i '' -E "s/^  version \".*\"$/  version \"$VERSION\"/" "$CASK_NEW"
sed -i '' -E "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" "$CASK_NEW"
grep -q "^  version \"$VERSION\"$" "$CASK_NEW" && grep -q "^  sha256 \"$SHA\"$" "$CASK_NEW" \
  || die "couldn't set version/sha256 in $CASK_NEW; has its layout changed?"
! grep -q PLACEHOLDER "$CASK_NEW" || die "$CASK_NEW still contains a placeholder"
grep -E '^  (version|sha256|url) ' "$CASK_NEW" | indent

# `brew style` on the file path: `brew style --cask <token>` has to load the
# cask through tap trust, while the path form applies the same cask cops
# without evaluating anything.
STYLE="$(brew style "$CASK_NEW" 2>&1)" || die "brew style found problems (fix them in $TEMPLATE too):" "$STYLE"
ok "brew style: $(tail -1 <<<"$STYLE")"

# What the tap would gain, so a default run shows the change without making it.
if [ -f "$CASK" ]; then
  diff -u --label "tap: Casks/winbar.rb" --label "prepared: $CASK_NEW" "$CASK" "$CASK_NEW" | indent || true
fi
ok "prepared $CASK_NEW (the tap checkout is untouched so far)"

if ! grep -qi winbar "$TAP/README.md" 2>/dev/null; then
  warn "the tap's README.md doesn't mention winbar yet; worth a section next to untofu"
fi

# ---------------------------------------------------------------- publish ---

GH_EXTRA=()
case "$VERSION" in *-*) GH_EXTRA+=(--prerelease) ;; esac
PRERELEASE_FLAG="${GH_EXTRA[*]+ ${GH_EXTRA[*]}}"

# The publishing commands, in order. Printed as-is when not publishing, and
# from the point of failure when a --publish step fails, so the way forward is
# always a copy-paste rather than a re-run (a re-run would stop at "tag exists").
FINISH=(
  "git push $REMOTE $PUSH_SPEC refs/tags/$TAG"
  "gh release create $TAG $DMG --repo $REPO --title \"Winbar $VERSION\" --notes-file $NOTES_FILE --verify-tag$PRERELEASE_FLAG"
  "curl -sfL \"$ASSET_URL\" | shasum -a 256    # must print $SHA"
  "cp $CASK_NEW \"$CASK\" && git -C \"$TAP\" add Casks/winbar.rb && git -C \"$TAP\" commit -m \"winbar $VERSION\" && git -C \"$TAP\" push"
)
finish_from() {
  local i="$1"
  printf '\n  From %s:\n\n' "$ROOT"
  while [ "$i" -lt "${#FINISH[@]}" ]; do
    printf '    %s\n' "${FINISH[$i]}"
    i=$((i + 1))
  done
  echo
}

if [ "$PUBLISH" = 0 ]; then
  echo
  echo "Built, notarized and tagged. Nothing has been pushed and the tap checkout is untouched;"
  echo "to publish:"
  finish_from 0
  cat <<EOS
  Then: brew update && brew upgrade --cask winbar
        brew audit --cask --online $TAP_NAME/winbar

  To abandon this release instead (the tap has nothing to undo):
    git tag -d $TAG
EOS
  exit 0
fi

step "Pushing $PUSH_SPEC and $TAG to $REMOTE"
if ! git push "$REMOTE" "$PUSH_SPEC" "refs/tags/$TAG"; then
  finish_from 0 >&2
  die "push failed; nothing is published yet. Once it's fixed, run the commands above."
fi

step "Creating the GitHub release $TAG on $REPO"
# --verify-tag: use the annotated tag just pushed; never let gh invent a
# lightweight one at some other commit.
if ! gh release create "$TAG" "$DMG" --repo "$REPO" --title "Winbar $VERSION" \
  --notes-file "$NOTES_FILE" --verify-tag ${GH_EXTRA[@]+"${GH_EXTRA[@]}"}; then
  finish_from 1 >&2
  die "gh release create failed. The tag is pushed; finish with the commands above."
fi

step "Checking the published asset is the disk image that was notarized"
# The cask's sha256 is right only if GitHub serves exactly these bytes. Check
# before pushing the tap, so nobody is ever pointed at a mismatch.
# --retry-all-errors as well as --retry: on its own, --retry covers connection
# failures, timeouts, 408, 429 and 5xx, but NOT the 404 this retry exists to
# absorb — GitHub can take a few seconds to serve an asset it has just
# accepted, and -f turns that 404 into an immediate exit 22.
if ! curl -sfL --retry 5 --retry-delay 3 --retry-all-errors -o "$WORK/published.dmg" "$ASSET_URL"; then
  finish_from 2 >&2
  die "the asset isn't reachable at $ASSET_URL, and the tap was NOT pushed. Once it is, finish with the commands above."
fi
[ "$(sha256_of "$WORK/published.dmg")" = "$SHA" ] \
  || die "the downloaded asset doesn't match what was built, so the tap was NOT pushed." \
    "Compare: curl -sfL \"$ASSET_URL\" | shasum -a 256   (expected $SHA)"
ok "fetched; sha256 matches"

# Only now, with the published asset fetched and its sha256 confirmed, does
# anything land in the tap checkout: the commit and the push are one step, so
# there is no state where the tap holds a cask pointing at a file nobody can
# download.
step "Committing the cask in the tap and pushing it"
mkdir -p "$TAP/Casks"
cp "$CASK_NEW" "$CASK"
git -C "$TAP" add Casks/winbar.rb
git -C "$TAP" commit -q -m "winbar $VERSION" \
  || die "nothing to commit in the tap; is Casks/winbar.rb already at $VERSION with this sha256?"
ok "committed in the tap: $(git -C "$TAP" log -1 --format='%h %s')"
if ! git -C "$TAP" push; then
  die "tap push failed. The release is live; users see it once the tap is pushed." \
    "git -C \"$TAP\" push"
fi

cat <<EOS

Winbar $VERSION is out: https://github.com/$REPO/releases/tag/$TAG

  brew update && brew upgrade --cask winbar
  brew audit --cask --online $TAP_NAME/winbar
EOS
