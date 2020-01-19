#!/bin/bash

set -eu

mount -o remount,rw /sys/fs/selinux

"$@" || exit $?
