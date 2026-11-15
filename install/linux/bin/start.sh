#!/bin/bash
cd "$(dirname "$0")"
export LD_LIBRARY_PATH="/home/chuyun/devQt/pkgs/deps/usr/lib/x86_64-linux-gnu:$(dirname "$0")/lib:$LD_LIBRARY_PATH"
./ros_qt5_gui_app