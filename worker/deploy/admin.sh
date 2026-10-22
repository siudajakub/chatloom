#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
action=${1:-inspect}
case "$action" in inspect|pair|enqueue|verify) ;; *) exit 64 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run through sudo on the worker host.' >&2; exit 1; }
if systemctl is-active --quiet personal-worker.service || systemctl is-active --quiet personal-worker-session.service; then
  echo 'Stop the worker/session before offline administration.' >&2
  exit 1
fi
state_volume=$(cat /etc/personal-worker/state-volume.path)
set -- "$action" /etc/personal-worker/config.json
case "$action" in enqueue|verify) set -- "$@" /var/lib/personal-worker/acceptance-sources.json ;; esac
exec systemd-run --quiet --collect --wait --pipe --unit=personal-worker-admin \
  --property=User=personalworker --property=Group=personalworker \
  --property=WorkingDirectory=/opt/personal-worker \
  --property=RuntimeDirectory=personal-worker --property=RuntimeDirectoryMode=0700 \
  --property=StateDirectory=personal-worker --property=StateDirectoryMode=0700 \
  --property="BindPaths=$state_volume:/var/lib/personal-worker" \
  --property=LoadCredential=credentials.json:/etc/personal-worker/credentials.json \
  --property=UMask=0077 --property=NoNewPrivileges=true \
  --property=KillMode=control-group --property=OOMPolicy=kill \
  --property=MemoryHigh=768M --property=MemoryMax=1536M --property=MemorySwapMax=0 \
  --property=TasksMax=128 --property=CPUQuota=100% --property=TimeoutStopSec=45 \
  --property=ProtectSystem=strict --property=ProtectHome=true --property=PrivateTmp=true \
  --property='ReadWritePaths=/var/lib/personal-worker /run/personal-worker' \
  --property=Environment=FFMPEG_PATH=/usr/bin/ffmpeg \
  --property=Environment=FFPROBE_PATH=/usr/bin/ffprobe \
  /bin/sh -c '/usr/bin/python3 /opt/personal-worker/prepare_credentials.py && exec /opt/personal-worker/admin/bin/admin "$@"' sh "$@"
