#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
task_media_root="${1:-$(pwd)/.runtime/media}"
case "$task_media_root" in /*) ;; *) echo 'Runtime directory must be absolute' >&2; exit 64;; esac
mkdir -p "$task_media_root/tmp" "$task_media_root/cache"
task_python="$(command -v python3)"
if command -v uv >/dev/null 2>&1; then
  env TMPDIR="$task_media_root/tmp" UV_CACHE_DIR="$task_media_root/cache" UV_PYTHON_DOWNLOADS=never \
    uv venv --python "$task_python" "$task_media_root/venv"
  env TMPDIR="$task_media_root/tmp" UV_CACHE_DIR="$task_media_root/cache" \
    uv pip install --python "$task_media_root/venv/bin/python" --index-url https://pypi.org/simple --only-binary :all: imageio-ffmpeg==0.6.0
else
  env TMPDIR="$task_media_root/tmp" "$task_python" -m venv "$task_media_root/venv"
  env TMPDIR="$task_media_root/tmp" PIP_CACHE_DIR="$task_media_root/cache" \
    "$task_media_root/venv/bin/python" -m pip --isolated --cache-dir "$task_media_root/cache" install --index-url https://pypi.org/simple --only-binary=:all: imageio-ffmpeg==0.6.0
fi
"$task_media_root/venv/bin/python" - "$task_media_root" <<'PY'
import hashlib,json,os,pathlib,shlex,subprocess,sys
root=pathlib.Path(sys.argv[1]).resolve()
os.environ.pop('IMAGEIO_FFMPEG_EXE',None)
import imageio_ffmpeg
binary=pathlib.Path(imageio_ffmpeg.get_ffmpeg_exe()).resolve()
if not binary.is_relative_to(root/'venv') or not binary.is_file():
    raise SystemExit('Refuse non-wheel ffmpeg binary')
subprocess.run([str(binary),'-version'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
(root/'runtime.json').write_text(json.dumps({'package':'imageio-ffmpeg','version':imageio_ffmpeg.__version__,'ffmpegVersion':imageio_ffmpeg.get_ffmpeg_version(),'binarySha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'binary':str(binary)},indent=2)+'\n')
(root/'runtime.env').write_text('FFMPEG_PATH='+shlex.quote(str(binary))+'\nFFPROBE_PATH=\n')
os.chmod(root/'runtime.env',0o600)
print('PASS: pinned imageio-ffmpeg wheel and native binary; ffprobe intentionally absent.')
PY
printf '%s\n' 'Runtime files are project-local. Source runtime.env for development; set absolute FFMPEG_PATH in service configuration for deployment.'
