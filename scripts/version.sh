#!/bin/sh
# The version rule, and the only place that knows where the version is written.
#
#   . scripts/version.sh
#   version_tree                 the version this tree builds
#   version_published            the newest release on GitHub, or 0.0.0 when there is none
#   version_next <x.y.z>         that version with its patch raised by one
#   version_set  <x.y.z>         write it everywhere it must agree
#   version_check                say whether the tree holds published + 1, and what to do if not
#
# **The tree is always one patch ahead of what is published.** A local install therefore carries a version
# no release can offer, so the installed copy is never told to replace itself with something older, and the
# copy on this Mac is always the newest that exists. Publishing makes the tree's version the published one,
# and raises the tree again.
set -u
VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"

# Where the version is written. The only place: the VERSION="..." line in scripts/make-app.sh, which writes
# it into the built Info.plist as both CFBundleShortVersionString and CFBundleVersion — unlike KoffeeLid,
# nothing here keeps a separately-rising build number.
version_tree() {
  sed -n 's/^VERSION="\(.*\)"$/\1/p' "$VERSION_ROOT/scripts/make-app.sh" | head -1
}

version_published() {
  tag="$(gh release list -R "$GITHUB_REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)"
  # No release, no network, no repository: all read as nothing published, which makes the tree's 0.0.1 right.
  [ -n "$tag" ] || { echo "0.0.0"; return 0; }
  echo "${tag#v}"
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

# Prints the version a build should carry and returns 0; prints why it cannot and returns 1.
version_check() {
  tree="$(version_tree)"; published="$(version_published)"; wanted="$(version_next "$published")"
  if [ "$tree" = "$wanted" ]; then echo "$tree"; return 0; fi
  # Ahead of the rule is a tree someone has already raised further; that is theirs to keep.
  if [ "$(printf '%s\n%s\n' "$wanted" "$tree" | sort -V | tail -1)" = "$tree" ]; then echo "$tree"; return 0; fi
  echo "the tree is at $tree, but $published is published: a build must be $wanted or newer." >&2
  echo "  scripts/version.sh holds the rule; 'version_set $wanted' writes it." >&2
  return 1
}
