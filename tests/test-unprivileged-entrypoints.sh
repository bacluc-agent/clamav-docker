#!/bin/sh

set -eu

root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)

run_case() {
    script=$1
    expected_socket=$2
    environment=${3:-}
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    config=$work/config
    runtime=$work/runtime
    mkdir -p "$config" "$runtime"
    printf 'User clamav\nLocalSocket /tmp/mounted.sock\n' > "$config/clamd.conf"
    printf 'DatabaseOwner clamav\n' > "$config/freshclam.conf"
    printf 'MilterSocket unix:/tmp/mounted-milter.sock\n' > "$config/clamav-milter.conf"
    entrypoint=$work/entrypoint
    sed "s|/etc/clamav|$config|g" "$root/$script" > "$entrypoint"
    chmod +x "$entrypoint"
    if [ -n "$environment" ]; then
        env CLAMD_CONF_LocalSocket="$environment" CLAMAV_RUNTIME_DIR="$runtime" \
            CLAMAV_NO_CLAMD=true CLAMAV_NO_FRESHCLAMD=true CLAMAV_NO_MILTERD=true \
            HOME="$work/home" TMPDIR="$work/tmp" sh "$entrypoint" sh -c "\
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"LocalSocket\" { count++; socket = \$2 } END { print count, socket }' '$runtime/clamd.conf')\" = '1 $expected_socket' && \
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"ClamdSocket\" { print \$2 }' '$runtime/clamav-milter.conf')\" = '$expected_socket' && \
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"MilterSocket\" { print \$2 }' '$runtime/clamav-milter.conf')\" = 'unix:$runtime/milter.sock'"
    else
        env CLAMAV_RUNTIME_DIR="$runtime" CLAMAV_NO_CLAMD=true \
            CLAMAV_NO_FRESHCLAMD=true CLAMAV_NO_MILTERD=true HOME="$work/home" \
            TMPDIR="$work/tmp" sh "$entrypoint" sh -c "\
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"LocalSocket\" { count++; socket = \$2 } END { print count, socket }' '$runtime/clamd.conf')\" = '1 $expected_socket' && \
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"ClamdSocket\" { print \$2 }' '$runtime/clamav-milter.conf')\" = '$expected_socket' && \
                test \"\$(awk '! /^[[:space:]]*#/ && \$1 == \"MilterSocket\" { print \$2 }' '$runtime/clamav-milter.conf')\" = 'unix:$runtime/milter.sock'"
    fi
    rm -rf "$work"
    trap - EXIT HUP INT TERM
}

for script in \
    clamav/1.4/alpine/scripts/docker-entrypoint-unprivileged.sh \
    clamav/1.4/debian/scripts/docker-entrypoint-unprivileged.sh \
    clamav/1.5/alpine/scripts/docker-entrypoint-unprivileged.sh \
    clamav/1.5/debian/scripts/docker-entrypoint-unprivileged.sh \
    clamav/unstable/alpine/scripts/docker-entrypoint-unprivileged.sh \
    clamav/unstable/debian/scripts/docker-entrypoint-unprivileged.sh
do
    run_case "$script" /tmp/mounted.sock
    run_case "$script" /tmp/env.sock /tmp/env.sock
done
