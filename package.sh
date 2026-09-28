#!/usr/bin/env bash
set -euo pipefail

TAG=${1:?upstream release tag is required}
UPSTREAM_VERSION=${2:?upstream version is required}
VERSION=${3:?Debian package version is required}
ARCH=${4:?Debian architecture is required}
UPSTREAM_ARCH=${5:?upstream asset architecture is required}

UPSTREAM_REPO=mozilla/geckodriver
PACKAGE=$(awk '/^Package:/ { print $2; exit }' debian/control)
ASSET="geckodriver-v${UPSTREAM_VERSION}-${UPSTREAM_ARCH}.tar.gz"

case "${ARCH}:${UPSTREAM_ARCH}" in
  amd64:linux64|arm64:linux-aarch64) ;;
  *)
    echo "unsupported architecture mapping: ${ARCH}:${UPSTREAM_ARCH}" >&2
    exit 2
    ;;
esac

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DOWNLOAD="$WORK/download"
EXTRACT="$WORK/extract"
PKGROOT="$WORK/pkg"
DOCROOT="$PKGROOT/usr/share/doc/$PACKAGE"

mkdir -p "$DOWNLOAD" "$EXTRACT" "$PKGROOT/DEBIAN" "$PKGROOT/usr/bin" "$DOCROOT" "$ROOT/dist"

release_json=$(gh api "repos/${UPSTREAM_REPO}/releases/tags/${TAG}")
expected=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .digest // empty' <<<"$release_json")
if [[ ! $expected =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Missing SHA-256 digest for ${ASSET} in GitHub Release metadata" >&2
  exit 1
fi

gh release download "$TAG" \
  --repo "$UPSTREAM_REPO" \
  --pattern "$ASSET" \
  --dir "$DOWNLOAD"

actual=$(sha256sum "$DOWNLOAD/$ASSET" | awk '{print $1}')
if [[ "sha256:${actual}" != "$expected" ]]; then
  echo "GitHub Release digest mismatch for ${ASSET}" >&2
  exit 1
fi

tar -xzf "$DOWNLOAD/$ASSET" -C "$EXTRACT"
test -x "$EXTRACT/geckodriver"
"$EXTRACT/geckodriver" --version | head -n1 | grep -E "^geckodriver ${UPSTREAM_VERSION} \(.+\)$" >/dev/null
install -m 0755 "$EXTRACT/geckodriver" "$PKGROOT/usr/bin/geckodriver"

# Preserve the upstream MPL-2.0 license without carrying upstream source code
# in this packaging repository.
gh api "repos/${UPSTREAM_REPO}/contents/LICENSE?ref=${TAG}" --jq .content | tr -d '\n' | base64 --decode > "$DOCROOT/LICENSE"
cat > "$DOCROOT/copyright" <<EOF2
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: geckodriver
Source: https://hg.mozilla.org/mozilla-central/file/tip/testing/geckodriver

Files: *
Copyright: Mozilla contributors
License: MPL-2.0
 See /usr/share/doc/${PACKAGE}/LICENSE.
EOF2
chmod 0644 "$DOCROOT/LICENSE" "$DOCROOT/copyright"
find "$PKGROOT" -type d -exec chmod 0755 {} +

installed_size=$(du -sk "$PKGROOT/usr" | awk '{print $1}')
awk -v version="$VERSION" -v arch="$ARCH" -v installed_size="$installed_size" '
  BEGIN { inserted = 0 }
  /^Description:/ && !inserted {
    print "Version: " version
    print "Architecture: " arch
    print "Installed-Size: " installed_size
    inserted = 1
  }
  { print }
' "$ROOT/debian/control" > "$PKGROOT/DEBIAN/control"
chmod 0644 "$PKGROOT/DEBIAN/control"

output="$ROOT/dist/${PACKAGE}_${VERSION}_${ARCH}.deb"
rm -f "$output"
dpkg-deb --build --root-owner-group "$PKGROOT" "$output"

dpkg-deb --info "$output" >/dev/null
contents=$(dpkg-deb --contents "$output")
grep -q './usr/bin/geckodriver' <<<"$contents"
grep -q "./usr/share/doc/${PACKAGE}/LICENSE" <<<"$contents"
grep -q "./usr/share/doc/${PACKAGE}/copyright" <<<"$contents"
echo "Built $output"
