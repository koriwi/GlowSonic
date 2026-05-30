#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.1.1" >&2
  exit 1
fi

VERSION="${1#v}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid version: $1" >&2
  echo "Use a version like 0.1.1" >&2
  exit 1
fi

ZIP="GlowSonic-${VERSION}.zip"
URL="https://github.com/koriwi/GlowSonic/releases/download/v${VERSION}/${ZIP}"

perl -0pi -e "s#<version>[^<]+</version>#<version>${VERSION}</version>#" \
  GlowSonic/install.xml

perl -0pi -e "s#(<plugin name=\"GlowSonic\" version=\")[^\"]+(\" minTarget=)#\${1}${VERSION}\${2}#" \
  repo.xml

perl -0pi -e "s#<url>[^<]+</url>#<url>${URL}</url>#" \
  repo.xml

perl -0pi -e 's#<sha>[^<]*</sha>#<sha></sha>#' \
  repo.xml

echo "Updated GlowSonic to ${VERSION}"
echo
echo "Next steps:"
echo "  git diff"
echo "  git add GlowSonic/install.xml repo.xml"
echo "  git commit -m \"Bump version to ${VERSION}\""
echo "  git push origin master"
echo "  git tag v${VERSION}"
echo "  git push origin v${VERSION}"
echo
echo "The release workflow will build the zip and update repo.xml with its SHA."
