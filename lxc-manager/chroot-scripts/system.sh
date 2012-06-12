#!/bin/bash
#
# LXC chroot system script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

set -e
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
USER=$1

# motd
rm -f /etc/motd

# satan user
useradd -d /home/satan -m -r -s /bin/bash -u 999 satan
chmod 700 /home/satan
cd /home/satan
git clone git://github.com/rootnode/satan.git prod
chown -R satan:satan /home/satan
