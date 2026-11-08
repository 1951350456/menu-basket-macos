#!/bin/zsh
# 向正在运行的收纳篮发送调试命令，例如：./dev-cmd.sh dump
# 仅对 ./build.sh --debug-ipc 构建的版本有效。
/usr/bin/osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.menubasket.cmd', '$*', \$(), true)" >/dev/null
