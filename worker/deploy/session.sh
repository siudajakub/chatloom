#!/bin/sh
# Interactive secrets stay in this private systemd PTY, never in argv or logs.
set -eu
action=${1:-enroll}
case "$action" in
  enroll|restore|check) ;;
  *) echo 'Usage: session.sh <enroll|restore|check>' >&2; exit 64 ;;
esac
[ "$(id -u)" = 0 ] || { echo 'Run through sudo on the worker host.' >&2; exit 1; }
if systemctl is-active --quiet personal-worker.service; then
  echo 'Stop the worker before accessing its encrypted session.' >&2
  exit 1
fi
state_volume=$(cat /etc/personal-worker/state-volume.path)
exec systemd-run --quiet --collect --wait --pty \
  --unit=personal-worker-session \
  --property=User=personalworker --property=Group=personalworker \
  --property=WorkingDirectory=/opt/personal-worker \
  --property=RuntimeDirectory=personal-worker --property=RuntimeDirectoryMode=0700 \
  --property=StateDirectory=personal-worker --property=StateDirectoryMode=0700 \
  --property="BindPaths=$state_volume:/var/lib/personal-worker" \
  --property=LoadCredential=credentials.json:/etc/personal-worker/credentials.json \
  --property=UMask=0077 --property=NoNewPrivileges=true \
  --property=ProtectSystem=strict --property=ProtectHome=true \
  --property=PrivateTmp=true \
  --property='ReadWritePaths=/var/lib/personal-worker /run/personal-worker' \
  --property=Environment=FFMPEG_PATH=/usr/bin/ffmpeg \
  --property=Environment=FFPROBE_PATH=/usr/bin/ffprobe \
  /bin/sh -c '/usr/bin/python3 /opt/personal-worker/prepare_credentials.py && exec /opt/personal-worker/bundle/bin/worker "$1" /etc/personal-worker/config.json' sh "$action"
