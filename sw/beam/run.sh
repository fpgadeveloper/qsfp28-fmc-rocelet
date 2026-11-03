#!/bin/bash
# Run a command of the beamforming demo in NVIDIA's Holoscan Sensor Bridge 3.0.0 container.
#
#   sw/beam/run.sh python3 rocelet_beam_app.py --source roce --preset 2 --rate 64
#   RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source roce --preset 2 --rate 64
#   sw/beam/run.sh bash
#
# ROCELET_DIR (default: two levels above this script) is the host directory that holds sw/beam/
# and sw/hsb/, normally a clone of qsfp28-fmc-rocelet. It is mounted at /beam and the command
# runs in /beam/sw/beam. --net host and --privileged give the container the 100G port, the RDMA
# device and the socket-buffer limits; the synthetic sources do not need them but do not mind.
#
# RL_WIN=1     add the X display for the Holoviz window (RL_DISPLAY, default :0; the X server
#              must accept local clients, e.g. 'xhost +local:' in the session)
# RL_IMAGE     the container image (default hololink-demo:3.0.0)
# RL_NAME      the container name (default rocelet-beam; 'docker stop rocelet-beam' sends SIGTERM,
#              which switches the board's data plane off)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROCELET_DIR=${ROCELET_DIR:-$(cd "$HERE/../.." && pwd)}
W=()
if [ -n "$RL_WIN" ]; then W=(-e DISPLAY="${RL_DISPLAY:-:0}" -v /tmp/.X11-unix:/tmp/.X11-unix); fi
T=()
if [ -t 0 ] && [ -t 1 ]; then T=(-it); fi
exec docker run --rm --init "${T[@]}" --net host --privileged --gpus all --runtime=nvidia \
  -e NVIDIA_DRIVER_CAPABILITIES=all --device /dev/nvidia-modeset \
  --ulimit stack=33554432 --shm-size=1g -e PYTHONDONTWRITEBYTECODE=1 "${W[@]}" \
  -v "$ROCELET_DIR":/beam -w /beam/sw/beam --name "${RL_NAME:-rocelet-beam}" \
  "${RL_IMAGE:-hololink-demo:3.0.0}" "$@"
