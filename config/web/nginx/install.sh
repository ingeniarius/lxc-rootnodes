#!/bin/bash
# Installation script 
# Nginx container configuration

# Exit on error
set -e

# Debug information
set -x

# Destination directory
ROOTFS="/lxc/system/nginx/rootfs"

# Dpkg selections
cp dpkg-selections $ROOTFS/root/

# Daemontools scripts
for daemon_name in agent nginx
do
	cp -r etc/service/$daemon_name $ROOTFS/etc/service/
	chmod 700                      $ROOTFS/etc/service/$daemon_name/run
done

# Nginx compilation script
[ -d "$ROOTFS/usr/src/nginx" ] || mkdir -p -m 700 "$ROOTFS/usr/src/nginx"
cp usr/src/nginx/run.sh $ROOTFS/usr/src/nginx/

# Nginx configuration
cp -rv etc/nginx $ROOTFS/etc/
