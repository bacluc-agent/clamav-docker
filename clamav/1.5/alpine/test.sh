#!/bin/sh

set -eu

image=${1:?image name is required}
root_name=clamav-alpine-15-root
user_name=clamav-alpine-15-user
cleanup() {
	docker rm -f "$root_name" "$user_name" >/dev/null 2>&1 || true
}
custom_config=$(mktemp)
printf 'LogTime no\n' > "$custom_config"
chmod 644 "$custom_config"
trap 'rm -f "$custom_config"; cleanup' EXIT HUP INT TERM

[ "$(docker run --rm --user clamav "$image" id -u)" = 100 ]
[ "$(docker run --rm --user clamav "$image" id -g)" = 101 ]
docker run --rm -e CLAMD_CONF_LogTime=no "$image" sh -c 'grep -q "^LogTime no$" /etc/clamav/clamd.conf'

docker run --rm --user 40000:40001 "$image" sh -c '
	test "$(id -u)" = 40000
	test "$(id -g)" = 40001
	test -w /var/lib/clamav
	test -w /var/log/clamav
	test -w /tmp
	touch /var/lib/clamav/arbitrary-user-test /var/log/clamav/arbitrary-user-test
rm /var/lib/clamav/arbitrary-user-test /var/log/clamav/arbitrary-user-test
file=$(mktemp /tmp/clamav-test.XXXXXX)
rm "$file"
'

config_hash=$(docker run --rm "$image" sha256sum /etc/clamav/clamd.conf)
docker run --rm --user 40000:40001 -e CLAMD_CONF_LogTime=no "$image" sh -c "test \"\$(sha256sum /etc/clamav/clamd.conf)\" = '$config_hash'"
docker run --rm --user 40000:40001 --mount "type=bind,src=$custom_config,dst=/etc/clamav/clamd.conf,readonly" "$image" sh -c 'grep -q "^LocalSocket /tmp/clamd.sock$" /tmp/clamav/clamd.conf'

docker run -d --name "$root_name" --user 0:0 "$image" >/dev/null
docker run -d --name "$user_name" --user 40000:40001 "$image" >/dev/null

wait_for_socket() {
	container=$1
	socket=$2
	wait=180
	while ! docker exec "$container" test -S "$socket"; do
		wait=$((wait - 1))
		[ "$wait" -gt 0 ] || return 1
		sleep 1
	done
}

wait_for_socket "$root_name" /tmp/clamd.sock
wait_for_socket "$user_name" /tmp/clamd.sock

docker exec "$root_name" sh -c 'printf "%s\n" '\''X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'\'' > /tmp/eicar.com'
if docker exec "$root_name" clamdscan --stream /tmp/eicar.com; then
	exit 1
fi

docker exec "$root_name" sh -c 'test "$(id -u)" = 0; test -S /tmp/clamd.sock'
docker exec "$user_name" sh -c 'test "$(id -u)" = 40000; test -S /tmp/clamd.sock'

mkdir -p "${TMPDIR:-/tmp}/clamav-restrictive"
chmod 700 "${TMPDIR:-/tmp}/clamav-restrictive"
if docker run --rm --user 40000:40001 --mount "type=bind,src=${TMPDIR:-/tmp}/clamav-restrictive,dst=/tmp" "$image" sh -c 'touch /tmp/must-not-be-created'; then
	exit 1
fi

docker stop "$user_name" >/dev/null
[ "$(docker inspect "$user_name" --format='{{.State.Status}}')" = exited ]
