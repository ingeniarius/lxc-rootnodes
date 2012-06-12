#!/bin/bash
# Installation script 
# MySQL container configuration

# Exit on error
set -e

# Debug information
set -x

# Destination directory
ROOTFS="/lxc/system/mysql/rootfs"

# MySQL config file
cp etc/mysql/my.cnf  $ROOTFS/etc/mysql/my.cnf

# Daemontools scripts
cp -r etc/service/agent $ROOTFS/etc/service/
chmod 700                $ROOTFS/etc/service/agent/run

exit
