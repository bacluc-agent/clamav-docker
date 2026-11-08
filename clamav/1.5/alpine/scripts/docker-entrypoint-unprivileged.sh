#!/sbin/tini /bin/sh
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

sed -e 's|.*\(User\) .*|#\1|' -e "s|.*\(LocalSocket\) .*|\1 $CLAMAV_RUNTIME_DIR/clamd.sock|" -e 's|^#\(LogFile\) .*|\1 /var/log/clamav/clamd.log|' /etc/clamav/clamd.conf > "$CLAMAV_RUNTIME_DIR/clamd.conf"
sed -e 's|.*\(DatabaseOwner\) .*|#\1|' -e "s|^#\(UpdateLogFile\) .*|\1 /var/log/clamav/freshclam.log|" -e "s|^#\(NotifyClamd\).*|\1 $CLAMAV_RUNTIME_DIR/clamd.conf|" /etc/clamav/freshclam.conf > "$CLAMAV_RUNTIME_DIR/freshclam.conf"
sed -e 's|.*\(User\) .*|#\1|' -e "s|.*\(MilterSocket\) .*|\1 unix:$CLAMAV_RUNTIME_DIR/milter.sock|" /etc/clamav/clamav-milter.conf > "$CLAMAV_RUNTIME_DIR/clamav-milter.conf"

env | grep '^CLAMD_CONF_' | while IFS='=' read -r KEY VALUE; do
    TRIMMED="${KEY#CLAMD_CONF_}"
    grep -q "^#$TRIMMED " "$CLAMAV_RUNTIME_DIR/clamd.conf" && sed -i "s/^#$TRIMMED .*/$TRIMMED $VALUE/" "$CLAMAV_RUNTIME_DIR/clamd.conf" || sed -i "\$ a\\$TRIMMED $VALUE" "$CLAMAV_RUNTIME_DIR/clamd.conf"
done
env | grep '^FRESHCLAM_CONF_' | while IFS='=' read -r KEY VALUE; do
    TRIMMED="${KEY#FRESHCLAM_CONF_}"
    grep -q "^#$TRIMMED " "$CLAMAV_RUNTIME_DIR/freshclam.conf" && sed -i "s/^#$TRIMMED .*/$TRIMMED $VALUE/" "$CLAMAV_RUNTIME_DIR/freshclam.conf" || sed -i "\$ a\\$TRIMMED $VALUE" "$CLAMAV_RUNTIME_DIR/freshclam.conf"
done

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
			/etc/clamav/freshclam.conf > /tmp/freshclam_initial.conf
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
		if [ -S "$CLAMAV_RUNTIME_DIR/clamd.sock" ]; then
			unlink "$CLAMAV_RUNTIME_DIR/clamd.sock"
		fi
		clamd --config-file="$CLAMAV_RUNTIME_DIR/clamd.conf" --foreground &
		while [ ! -S "$CLAMAV_RUNTIME_DIR/clamd.sock" ]; do
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
