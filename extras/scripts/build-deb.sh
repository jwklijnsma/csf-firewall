#!/usr/bin/env bash
# #
#   @desc               builds a Debian/Ubuntu .deb package of CSF
#   @usage              extras/scripts/build-deb.sh <version> [output-dir]
#                       extras/scripts/build-deb.sh 15.11.1 dist/
#                       CSF_SOURCE_ROOT=/path/to/checkout extras/scripts/build-deb.sh 15.11 dist/
#
#   @layout             The package ships the release tree in /usr/share/csf-firewall/csf and
#                       runs the regular CSF installer (install.sh) from postinst. That keeps
#                       one install path for .deb, tarball and `csf -u`, and the installer
#                       already preserves existing configs on upgrade.
#
#                       apt remove   → stops and disables csf/lfd; files and /etc/csf are kept
#                       apt purge    → full uninstall, including /etc/csf and /var/lib/csf
#
#   @apt                The package also installs /etc/apt/sources.list.d/csf-firewall.sources so
#                       "apt-get update && apt-get upgrade" installs new releases.
#                       APT_KEYRING=<binary keyring>  → repo is verified with that key (Signed-By)
#                       not set                      → repo is trusted over HTTPS only (Trusted: yes)
#                       APT_REPO_URL overrides the repository URL.
# #

set -euo pipefail

VERSION="${1:?usage: $0 <version> [output-dir]}"
OUTDIR="${2:-.}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# CSF_SOURCE_ROOT packages another checkout (e.g. an older release tag) with this script
ROOT="$(cd "${CSF_SOURCE_ROOT:-${ROOT}}" && pwd)"
[ -f "${ROOT}/src/csf.pl" ] || { echo "error: no CSF source in ${ROOT}" >&2; exit 1; }
PKG="csf-firewall"

# Debian versions sort "~" before anything, so 15.11-rc.1 → 15.11~rc.1 (older than 15.11)
DEB_VERSION="$(printf '%s' "${VERSION#v}" | sed 's/-/~/')"

if ! printf '%s' "${DEB_VERSION}" | grep -Eq '^[0-9][0-9A-Za-z.+~]*$'; then
    echo "error: '${VERSION}' is not a valid Debian version" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PKGROOT="${WORK}/${PKG}"
SHARE="${PKGROOT}/usr/share/${PKG}"
DOC="${PKGROOT}/usr/share/doc/${PKG}"

mkdir -p "${SHARE}/csf" "${DOC}" "${PKGROOT}/DEBIAN"

# #
#   Payload: same csf/ tree as the release archive
# #

cp -r "${ROOT}/src/." "${SHARE}/csf/"
cp "${ROOT}/README.md" "${ROOT}/LICENSE.md" "${SHARE}/csf/"
printf '%s\n' "${VERSION#v}" > "${SHARE}/csf/version.txt"

find "${SHARE}" -type d -exec chmod 0755 {} +
find "${SHARE}" -type f -exec chmod 0644 {} +

# Anything with an absolute #!/ interpreter is executable (includes da/, interworx/, webmin/ scripts).
# Bundled Perl modules with "#!perl" stay 0644; they are libraries, not scripts.
find "${SHARE}/csf" -type f -print0 | while IFS= read -r -d '' f; do
    if [ "$(head -c3 "$f" | tr -d '\000')" = "#!/" ]; then chmod 0755 "$f"; fi
done

# #
#   Docs
# #

cat > "${DOC}/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: csf-firewall
Source: https://github.com/jwklijnsma/csf-firewall

Files: *
Copyright: 2006-2025 Jonathan Michaelson, Way to the Web Ltd.
           2025-2026 Aetherinox
License: GPL-3+
 On Debian systems, the full text of the GNU General Public License
 version 3 can be found in /usr/share/common-licenses/GPL-3.
EOF

if [ -f "${ROOT}/src/changelog.txt" ]; then
    gzip -9n < "${ROOT}/src/changelog.txt" > "${DOC}/changelog.gz"
fi

# #
#   APT source, so apt-get upgrade picks up new releases
# #

APT_REPO_URL="${APT_REPO_URL:-https://raw.githubusercontent.com/jwklijnsma/csf-firewall/dist/apt/}"
mkdir -p "${PKGROOT}/etc/apt/sources.list.d"

if [ -n "${APT_KEYRING:-}" ]; then
    mkdir -p "${PKGROOT}/usr/share/keyrings"
    install -m 0644 "${APT_KEYRING}" "${PKGROOT}/usr/share/keyrings/csf-firewall.gpg"
    APT_AUTH="Signed-By: /usr/share/keyrings/csf-firewall.gpg"
else
    APT_AUTH="Trusted: yes"
fi

cat > "${PKGROOT}/etc/apt/sources.list.d/csf-firewall.sources" <<SRCEOF
# csf-firewall releases, installed by the csf-firewall package.
# Remove this file (or purge the package) to stop receiving updates via apt.
Types: deb
URIs: ${APT_REPO_URL}
Suites: ./
${APT_AUTH}
SRCEOF
chmod 0644 "${PKGROOT}/etc/apt/sources.list.d/csf-firewall.sources"

# Third-party packages ship their own APT source (like Chrome and VS Code); the rule is meant
# for packages in the Debian archive, so override it for this package.
mkdir -p "${PKGROOT}/usr/share/lintian/overrides"
echo "csf-firewall: package-installs-apt-sources [etc/apt/sources.list.d/csf-firewall.sources]" \
    > "${PKGROOT}/usr/share/lintian/overrides/csf-firewall"
chmod 0644 "${PKGROOT}/usr/share/lintian/overrides/csf-firewall"

# #
#   Monthly automatic upgrade (systemd timer)
#
#   csf-firewall-upgrade.timer runs once a month (random delay up to 6h, catches up after downtime)
#   and upgrades only this package from its own APT source. Settings in csf.conf are kept.
#   Opt out: AUTO_UPGRADE="no" in /etc/default/csf-firewall, or
#            systemctl disable --now csf-firewall-upgrade.timer
# #

mkdir -p "${PKGROOT}/usr/lib/csf-firewall" "${PKGROOT}/usr/lib/systemd/system" "${PKGROOT}/etc/default"

cat > "${PKGROOT}/etc/default/csf-firewall" <<'CFGEOF'
# csf-firewall package settings

# Upgrade csf-firewall automatically once a month from its APT repository
# (csf-firewall-upgrade.timer). Set to "no" to only upgrade manually with apt.
AUTO_UPGRADE="yes"
CFGEOF

cat > "${PKGROOT}/usr/lib/csf-firewall/auto-upgrade" <<'UPGEOF'
#!/bin/sh
# Upgrades the csf-firewall package from its own APT source. Run by csf-firewall-upgrade.timer.
set -eu

[ -r /etc/default/csf-firewall ] && . /etc/default/csf-firewall
case "${AUTO_UPGRADE:-yes}" in
    yes|YES|1|true) ;;
    *) echo "csf-firewall: automatic upgrade disabled in /etc/default/csf-firewall"; exit 0 ;;
esac

SOURCE=/etc/apt/sources.list.d/csf-firewall.sources
if [ ! -f "${SOURCE}" ]; then
    echo "csf-firewall: ${SOURCE} is missing, nothing to upgrade from"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
BEFORE=$(dpkg-query -W -f='${Version}' csf-firewall 2>/dev/null || echo none)

# Refresh only the csf-firewall source; keep the other repositories' package lists as they are
PARTS=$(mktemp -d)
trap 'rm -rf "${PARTS}"' EXIT
cp "${SOURCE}" "${PARTS}/"
apt-get update -qq \
    -o Dir::Etc::sourcelist=/dev/null \
    -o Dir::Etc::sourceparts="${PARTS}" \
    -o APT::Get::List-Cleanup=0

# Upgrade only this package; keep locally changed config files
apt-get install -y -qq --only-upgrade \
    -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    csf-firewall

AFTER=$(dpkg-query -W -f='${Version}' csf-firewall 2>/dev/null || echo none)
if [ "${BEFORE}" = "${AFTER}" ]; then
    echo "csf-firewall: already up to date (${AFTER})"
else
    echo "csf-firewall: upgraded ${BEFORE} -> ${AFTER}"
fi
UPGEOF
chmod 0755 "${PKGROOT}/usr/lib/csf-firewall/auto-upgrade"

cat > "${PKGROOT}/usr/lib/systemd/system/csf-firewall-upgrade.service" <<'UNITEOF'
[Unit]
Description=Upgrade csf-firewall from its APT repository
Documentation=https://github.com/jwklijnsma/csf-firewall
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/csf-firewall/auto-upgrade
UNITEOF

cat > "${PKGROOT}/usr/lib/systemd/system/csf-firewall-upgrade.timer" <<'UNITEOF'
[Unit]
Description=Monthly upgrade of csf-firewall
Documentation=https://github.com/jwklijnsma/csf-firewall

[Timer]
OnCalendar=monthly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
chmod 0644 "${PKGROOT}/usr/lib/systemd/system/csf-firewall-upgrade.service" \
           "${PKGROOT}/usr/lib/systemd/system/csf-firewall-upgrade.timer" \
           "${PKGROOT}/etc/default/csf-firewall"

# #
#   Control
# #

INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "${PKGROOT}" | cut -f1)"

cat > "${PKGROOT}/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${DEB_VERSION}
Section: net
Priority: optional
Architecture: all
Maintainer: Jan Wiebe Klijnsma <janwiebek@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: perl, iptables, ipset, libwww-perl, liblwp-protocol-https-perl, libio-socket-ssl-perl, libnet-ssleay-perl, libio-socket-inet6-perl, libsocket6-perl, libnet-libidn-perl | libnet-libidn2-perl, libjson-perl, libtime-hires-perl | perl (>= 5.8), wget | curl, procps
Recommends: dnsutils, libcrypt-ssleay-perl, libgd-graph-perl, unzip, sendmail-bin | default-mta | mail-transport-agent
Suggests: gcc
Homepage: https://github.com/jwklijnsma/csf-firewall
Description: ConfigServer Security & Firewall (CSF) and Login Failure Daemon
 CSF is a stateful packet inspection firewall, login/intrusion detection
 and security application for Linux servers, built on iptables/ipset.
 .
 This package runs the regular CSF installer. After installation CSF is
 in TESTING mode: review /etc/csf/csf.conf, set TESTING = "0" and run
 "csf -ra" to activate it.
EOF

# #
#   Maintainer scripts
# #

cat > "${PKGROOT}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    configure)
        SRC=/usr/share/csf-firewall/csf

        # The installer reads/writes relative to its own folder and logs to stdout
        cd "${SRC}"
        sh ./install.sh

        # Restart running services after an upgrade so the new code is used
        if [ -n "$2" ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            if systemctl is-active --quiet csf.service || systemctl is-active --quiet lfd.service; then
                /usr/sbin/csf -ra >/dev/null 2>&1 || true
            fi
        fi

        # Monthly upgrade timer: enable on first install and on upgrade from versions before it
        # existed (<= 15.11.3). Later upgrades leave it as the admin set it.
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            if [ -z "$2" ] || dpkg --compare-versions "$2" le 15.11.3; then
                systemctl enable --now csf-firewall-upgrade.timer >/dev/null 2>&1 || true
            fi
        fi

        if grep -Eq '^[[:space:]]*TESTING[[:space:]]*=[[:space:]]*"1"' /etc/csf/csf.conf 2>/dev/null; then
            echo ""
            echo "  csf-firewall: CSF is in TESTING mode. Edit /etc/csf/csf.conf, set TESTING = \"0\","
            echo "  then run: csf -ra"
            echo ""
        fi

        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "  csf-firewall: WARNING: ufw is active. Disable it (ufw disable) before enabling CSF." >&2
        fi
        ;;
esac

exit 0
EOF

cat > "${PKGROOT}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    remove|deconfigure)
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl stop lfd.service csf.service >/dev/null 2>&1 || true
            systemctl disable lfd.service csf.service >/dev/null 2>&1 || true
            systemctl disable --now csf-firewall-upgrade.timer >/dev/null 2>&1 || true
        fi
        # Flush CSF rules so the server is not left with a half-configured firewall
        if [ -x /usr/sbin/csf ]; then
            /usr/sbin/csf -f >/dev/null 2>&1 || true
        fi
        ;;
esac

exit 0
EOF

cat > "${PKGROOT}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    purge)
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl stop lfd.service csf.service >/dev/null 2>&1 || true
            systemctl disable lfd.service csf.service >/dev/null 2>&1 || true
        fi
        rm -f /usr/lib/systemd/system/csf.service /usr/lib/systemd/system/lfd.service \
              /lib/systemd/system/csf.service /lib/systemd/system/lfd.service \
              /etc/init.d/csf /etc/init.d/lfd \
              /usr/sbin/csf /usr/sbin/lfd \
              /etc/cron.d/csf_update /etc/cron.d/lfd-cron /etc/cron.d/csf-cron \
              /etc/logrotate.d/lfd /usr/local/man/man1/csf.man.1
        rm -rf /etc/csf /usr/local/csf /var/lib/csf
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        ;;
esac

exit 0
EOF

chmod 0755 "${PKGROOT}/DEBIAN/postinst" "${PKGROOT}/DEBIAN/prerm" "${PKGROOT}/DEBIAN/postrm"

printf '%s\n' /etc/apt/sources.list.d/csf-firewall.sources /etc/default/csf-firewall > "${PKGROOT}/DEBIAN/conffiles"

# #
#   Build
# #

mkdir -p "${OUTDIR}"
OUT="${OUTDIR%/}/${PKG}_${DEB_VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "${PKGROOT}" "${OUT}" >/dev/null
echo "${OUT}"
