#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
task_spike_root="$(mktemp -d "${TMPDIR:-/tmp}/personal-worker-spike.XXXXXXXX")"
trap 'rm -rf "$task_spike_root"' EXIT
python3 - "$task_spike_root" "$(pwd)/build/native/bundle/lib" <<'PY'
import json,secrets,sys,pathlib,os
root=pathlib.Path(sys.argv[1])
credential=root/'credentials.json'
credential.write_text(json.dumps({'databaseCipher':secrets.token_hex(32)}))
os.chmod(credential,0o600)
(root/'config.json').write_text(json.dumps({'stateDirectory':str(root/'state'),'temporaryDirectory':str(root/'audio'),'credentialsPath':str(credential),'nativeLibraryDirectory':sys.argv[2],'journalRoomId':'','trustedDeviceIds':[]}))
PY
build/native/bundle/bin/worker native-check "$task_spike_root/config.json"
printf '%s\n' 'Native initialization and SQLCipher smoke PASS (synthetic, no account).'
