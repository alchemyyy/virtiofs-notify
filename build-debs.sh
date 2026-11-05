#!/bin/bash
# Build virtiofs-notify-host and virtiofs-notify-guest .debs (needs dpkg-deb).
#   ./build-debs.sh [OUTDIR]     default OUTDIR: dist/
set -euo pipefail
umask 022

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/dist}
mkdir -p "$out"

stage_host() {
    install -D -m 0755 "$here/host/virtiofs-notify-host" "$1/usr/sbin/virtiofs-notify-host"
    install -D -m 0644 "$here/host/virtiofs-notify-host.service" \
        "$1/usr/lib/systemd/system/virtiofs-notify-host.service"
}

stage_guest() {
    # DKMS source directory: <PACKAGE_NAME>-<PACKAGE_VERSION> from dkms.conf.
    local src=$1/usr/src/inotify-trigger-1.0
    install -D -m 0755 "$here/guest/virtiofs-notify-guest" "$1/usr/sbin/virtiofs-notify-guest"
    install -D -m 0644 "$here/guest/virtiofs-notify-guest.service" \
        "$1/usr/lib/systemd/system/virtiofs-notify-guest.service"
    install -d "$src"
    install -m 0644 "$here"/guest/inotify_trigger/{inotify_trigger.c,Makefile,dkms.conf} "$src/"
}

build() {
    local pkg=$1 root version
    root=$(mktemp -d)
    chmod 0755 "$root"
    "stage_$pkg" "$root"
    install -d "$root/DEBIAN"
    install -m 0644 "$here/debian/$pkg/control" "$root/DEBIAN/control"
    install -m 0755 "$here/debian/$pkg"/{postinst,prerm,postrm} "$root/DEBIAN/"
    version=$(awk '$1 == "Version:" { print $2 }' "$here/debian/$pkg/control")
    dpkg-deb --root-owner-group --build "$root" "$out/virtiofs-notify-${pkg}_${version}_all.deb"
    rm -rf "$root"
}

build host
build guest
