#!/usr/bin/env bash
# #
#   @desc               builds a flat APT repository from one or more .deb files
#   @usage              extras/scripts/build-apt-repo.sh <output-dir> <file.deb> [file.deb ...]
#
#   @signing            APT_SIGNING_KEY  ASCII-armored private GPG key (no passphrase).
#                                        When set, InRelease and Release.gpg are written.
#                                        When empty, the repository is unsigned and clients
#                                        use "Trusted: yes" (HTTPS only).
#
#   @client             /etc/apt/sources.list.d/csf-firewall.sources (installed by the package):
#                           Types: deb
#                           URIs: https://raw.githubusercontent.com/jwklijnsma/csf-firewall/dist/apt/
#                           Suites: ./
#                           Signed-By: /usr/share/keyrings/csf-firewall.gpg   (or Trusted: yes)
# #

set -euo pipefail

OUT="${1:?usage: $0 <output-dir> <file.deb> [file.deb ...]}"
shift
[ "$#" -gt 0 ] || { echo "error: no .deb files given" >&2; exit 1; }

command -v apt-ftparchive >/dev/null || { echo "error: apt-ftparchive missing (apt-get install apt-utils)" >&2; exit 1; }

mkdir -p "${OUT}"
for deb in "$@"; do
    cp "${deb}" "${OUT}/"
done

cd "${OUT}"

apt-ftparchive packages . > Packages
gzip -9nk -f Packages

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="csf-firewall" \
    -o APT::FTPArchive::Release::Label="csf-firewall" \
    -o APT::FTPArchive::Release::Suite="stable" \
    -o APT::FTPArchive::Release::Codename="stable" \
    -o APT::FTPArchive::Release::Architectures="all amd64 arm64 armhf i386 ppc64el s390x riscv64" \
    -o APT::FTPArchive::Release::Description="ConfigServer Security & Firewall (jwklijnsma fork)" \
    release . > Release

rm -f InRelease Release.gpg

if [ -n "${APT_SIGNING_KEY:-}" ]; then
    GNUPGHOME="$(mktemp -d)"
    export GNUPGHOME
    trap 'rm -rf "${GNUPGHOME}"' EXIT

    printf '%s\n' "${APT_SIGNING_KEY}" | gpg --batch --quiet --import
    KEYID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}')"

    gpg --batch --yes --pinentry-mode loopback --default-key "${KEYID}" --clearsign -o InRelease Release
    gpg --batch --yes --pinentry-mode loopback --default-key "${KEYID}" -abs -o Release.gpg Release

    # Public key next to the repo, for manual setups
    gpg --batch --armor --export "${KEYID}" > csf-firewall.asc
    echo "signed with ${KEYID}" >&2
else
    echo "unsigned repository (APT_SIGNING_KEY not set)" >&2
fi
