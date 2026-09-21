#!/bin/sh
# The version rule, and the only place that knows where the version is written.
#
#   . scripts/version.sh
#   version_tree                        the version this tree builds
#   version_bump <patch|minor|major> <x.y.z>   that version raised by one level
#   version_set  <x.y.z>                write it everywhere it must agree
#
# The tree always holds exactly the version last published, or the version a local install just carried,
# whichever happened last — never a bumped-ahead placeholder. `scripts/publish.sh <level>` is the only thing
# that moves the version: it bumps, commits and pushes before it builds, so the commit it tags is the commit
# that carries the version it releases.
set -u
VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"

# Where the version is written. The only place: the VERSION="..." line in scripts/make-app.sh, which writes
# it into the built Info.plist as both CFBundleShortVersionString and CFBundleVersion — unlike KoffeeLid,
# nothing here keeps a separately-rising build number.
version_tree() {
  sed -n 's/^VERSION="\(.*\)"$/\1/p' "$VERSION_ROOT/scripts/make-app.sh" | head -1
}

version_bump() {
  level="${1:?version_bump <patch|minor|major> <x.y.z>}"
  v="${2:?version_bump <patch|minor|major> <x.y.z>}"
  major="${v%%.*}"; rest="${v#*.}"
  minor="${rest%%.*}"; patch="${rest#*.}"
  case "$level" in
    patch) echo "$major.$minor.$((patch + 1))" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    major) echo "$((major + 1)).0.0" ;;
    *) echo "version_bump: level must be patch, minor or major, not '$level'" >&2; return 1 ;;
  esac
}

version_set() {
  v="${1:?version_set <x.y.z>}"
  /usr/bin/sed -i '' -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$v\"/" "$VERSION_ROOT/scripts/make-app.sh"
}
