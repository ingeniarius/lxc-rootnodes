#!/bin/bash
set -e

ROOTFS="/lxc/system/mysql/rootfs"

# MySQL config file
cp my.cnf $ROOTFS/etc/mysql/my.cnf
