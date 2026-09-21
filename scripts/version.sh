#!/bin/sh
# The version rule, and the only place that knows where the version is written.
#
#   . scripts/version.sh
#   version_tree                 the version this tree builds
#   version_next <x.y.z>         that version with its patch raised by one
#   version_set  <x.y.z>         write it everywhere it must agree
#
# A local install always builds and installs exactly the tree's own version — the same version production
# runs, until the tree is next bumped. Publishing is the only thing that moves the version: it releases the
# tree's version as it stands, then raises the tree to the next patch so that version is never built again.
set -u
VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"

# Where the version is written. The only place: the VERSION="..." line in scripts/make-app.sh, which writes
# it into the built Info.plist as both CFBundleShortVersionString and CFBundleVersion — unlike KoffeeLid,
# nothing here keeps a separately-rising build number.
version_tree() {
  sed -n 's/^VERSION="\(.*\)"$/\1/p' "$VERSION_ROOT/scripts/make-app.sh" | head -1
}

version_next() {
  v="${1:?version_next <x.y.z>}"
  major="${v%%.*}"; rest="${v#*.}"
  minor="${rest%%.*}"; patch="${rest#*.}"
  echo "$major.$minor.$((patch + 1))"
}

version_set() {
  v="${1:?version_set <x.y.z>}"
  /usr/bin/sed -i '' -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$v\"/" "$VERSION_ROOT/scripts/make-app.sh"
}
