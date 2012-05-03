#!/bin/bash
#
# LXC chroot user script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

# TODO
# * disable rsyslog sendsigs_omit

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
USER=$1

# apache2 and php5
aptitude -q -y update
aptitude -q -y install php5 php5-cgi php5-cli php5-common php5-curl php5-dev php5-gd php5-intl php5-json php5-mcrypt php5-mhash php5-mysql php5-sqlite php5-suhosin php5-xsl php-apc php-xml-parser php-soap apache2 libapache2-mod-php5

# smtp
aptitude -q -y install msmtp

# tools
aptitude -q -y install irssi 

# motd
echo -e "Rootnode from scratch." > /etc/motd

# Cleanup
aptitude clean
aptitude autoclean
