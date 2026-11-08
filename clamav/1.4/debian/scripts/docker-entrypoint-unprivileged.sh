#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (C) 2021 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2021-2023 Cisco Systems, Inc. and/or its affiliates. All rights reserved.
#
# A beginning user should be able to docker run image bash (or sh) without
# needing to learn about --entrypoint
# https://github.com/docker-library/official-images#consistency

set -eu

if [ -z "${HOME:-}" ] || [ ! -w "$HOME" ]; then HOME=/tmp/clamav-home; fi
if [ -z "${TMPDIR:-}" ] || [ ! -w "$TMPDIR" ]; then TMPDIR=/tmp/clamav-tmp; fi
export HOME TMPDIR
CLAMAV_RUNTIME_DIR="${CLAMAV_RUNTIME_DIR:-/tmp/clamav}"
mkdir -p "$HOME" "$HOME/.cache" "$TMPDIR" "$CLAMAV_RUNTIME_DIR"

CLAMD_CONFIG_LOCAL_SOCKET=$(awk '!/^[[:space:]]*#/ && $1 == "LocalSocket" { socket = $2 } END { print socket }' /etc/clamav/clamd.conf)

sed -e 's|.*\(User\) .*|#\1|' -e "s|.*\(LocalSocket\) .*|\1 $CLAMAV_RUNTIME_DIR/clamd.sock|" -e 's|^#\(LogFile\) .*|\1 /var/log/clamav/clamd.log|' /etc/clamav/clamd.conf > "$CLAMAV_RUNTIME_DIR/clamd.conf"
sed -e 's|.*\(DatabaseOwner\) .*|#\1|' -e "s|^#\(UpdateLogFile\) .*|\1 /var/log/clamav/freshclam.log|" -e "s|^#\(NotifyClamd\).*|\1 $CLAMAV_RUNTIME_DIR/clamd.conf|" /etc/clamav/freshclam.conf > "$CLAMAV_RUNTIME_DIR/freshclam.conf"
sed -e 's|.*\(User\) .*|#\1|' -e "s|.*\(MilterSocket\) .*|\1 unix:$CLAMAV_RUNTIME_DIR/milter.sock|" /etc/clamav/clamav-milter.conf > "$CLAMAV_RUNTIME_DIR/clamav-milter.conf"

env | grep '^CLAMD_CONF_' | while IFS='=' read -r KEY VALUE; do
    TRIMMED="${KEY#CLAMD_CONF_}"
    if grep -q "^#$TRIMMED " "$CLAMAV_RUNTIME_DIR/clamd.conf"; then
        sed -i "s|^#$TRIMMED .*|$TRIMMED $VALUE|" "$CLAMAV_RUNTIME_DIR/clamd.conf"
    elif grep -q "^[[:space:]]*$TRIMMED " "$CLAMAV_RUNTIME_DIR/clamd.conf"; then
        sed -i "s|^[[:space:]]*$TRIMMED .*|$TRIMMED $VALUE|" "$CLAMAV_RUNTIME_DIR/clamd.conf"
    else
        sed -i "\$ a\\$TRIMMED $VALUE" "$CLAMAV_RUNTIME_DIR/clamd.conf"
    fi
done
env | grep '^FRESHCLAM_CONF_' | while IFS='=' read -r KEY VALUE; do
    TRIMMED="${KEY#FRESHCLAM_CONF_}"
    if grep -q "^#$TRIMMED " "$CLAMAV_RUNTIME_DIR/freshclam.conf"; then
        sed -i "s|^#$TRIMMED .*|$TRIMMED $VALUE|" "$CLAMAV_RUNTIME_DIR/freshclam.conf" || \
            sed -i "\$ a\\$TRIMMED $VALUE" "$CLAMAV_RUNTIME_DIR/freshclam.conf"
    else
        sed -i "\$ a\\$TRIMMED $VALUE" "$CLAMAV_RUNTIME_DIR/freshclam.conf"
    fi
done

if [ "${CLAMD_CONF_LocalSocket+x}" = x ]; then
    CLAMD_CONFIG_LOCAL_SOCKET=$CLAMD_CONF_LocalSocket
fi

case "$CLAMD_CONFIG_LOCAL_SOCKET" in
    ""|/tmp/clamd.sock) ;;
    /*) sed -i "s|^LocalSocket .*|LocalSocket $CLAMD_CONFIG_LOCAL_SOCKET|" "$CLAMAV_RUNTIME_DIR/clamd.conf" ;;
    *) echo "LocalSocket must be an absolute path" >&2; exit 1 ;;
esac
CLAMD_SOCKET=$(awk '!/^[[:space:]]*#/ && $1 == "LocalSocket" { socket = $2 } END { print socket }' "$CLAMAV_RUNTIME_DIR/clamd.conf")
case "$CLAMD_SOCKET" in
    /*) ;;
    *) echo "LocalSocket must be an absolute path" >&2; exit 1 ;;
esac
if grep -q '^[[:space:]]*ClamdSocket[[:space:]]' "$CLAMAV_RUNTIME_DIR/clamav-milter.conf"; then
    sed -i "s|^[[:space:]]*ClamdSocket[[:space:]].*|ClamdSocket unix:$CLAMD_SOCKET|" "$CLAMAV_RUNTIME_DIR/clamav-milter.conf"
else
    printf 'ClamdSocket unix:%s\n' "$CLAMD_SOCKET" >> "$CLAMAV_RUNTIME_DIR/clamav-milter.conf"
fi

# run command if it is not starting with a "-" and is an executable in PATH
if [ "${#}" -gt 0 ] && \
   [ "${1#-}" = "${1}" ] && \
   command -v "${1}" > "/dev/null" 2>&1; then
	# Ensure healthcheck always passes
	CLAMAV_NO_CLAMD="true" exec "${@}"
else
	if [ "${#}" -ge 1 ] && \
	   [ "${1#-}" != "${1}" ]; then
		# If an argument starts with "-" pass it to clamd specifically
		exec clamd "${@}"
	fi
	# else default to running clamav's servers

	# Ensure we have some virus data, otherwise clamd refuses to start
	if [ ! -f "/var/lib/clamav/main.cvd" ]; then
		echo "Updating initial database"
		# Set "TestDatabases no" and remove "NotifyClamd" for initial download
		sed -e 's|^\(TestDatabases \)|\#\1|' \
			-e '$a TestDatabases no' \
			-e 's|^\(NotifyClamd \)|\#\1|' \
		    "$CLAMAV_RUNTIME_DIR/freshclam.conf" > /tmp/freshclam_initial.conf
		freshclam --foreground --stdout --config-file=/tmp/freshclam_initial.conf
		rm /tmp/freshclam_initial.conf
	fi

	if [ "${CLAMAV_NO_FRESHCLAMD:-false}" != "true" ]; then
		echo "Starting Freshclamd"
		freshclam --config-file="$CLAMAV_RUNTIME_DIR/freshclam.conf" \
		          --checks="${FRESHCLAM_CHECKS:-1}" \
		          --daemon \
		          --foreground \
		          --stdout \
			  &
	fi

	if [ "${CLAMAV_NO_CLAMD:-false}" != "true" ]; then
		echo "Starting ClamAV"
		if [ -S "$CLAMD_SOCKET" ]; then
			unlink "$CLAMD_SOCKET"
		fi
		clamd --config-file="$CLAMAV_RUNTIME_DIR/clamd.conf" --foreground &
		while [ ! -S "$CLAMD_SOCKET" ]; do
			if [ "${_timeout:=0}" -gt "${CLAMD_STARTUP_TIMEOUT:=1800}" ]; then
				echo
				echo "Failed to start clamd"
				exit 1
			fi
			printf "\r%s" "Socket for clamd not found yet, retrying (${_timeout}/${CLAMD_STARTUP_TIMEOUT}) ..."
			sleep 1
			_timeout="$((_timeout + 1))"
		done
		echo "socket found, clamd started."
	fi

	if [ "${CLAMAV_NO_MILTERD:-true}" != "true" ]; then
		echo "Starting clamav milterd"
		clamav-milter --config-file="$CLAMAV_RUNTIME_DIR/clamav-milter.conf" &
	fi

	# Wait forever (or until canceled)
	exec tail -f "/dev/null"
fi

exit 0
