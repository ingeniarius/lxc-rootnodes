#!/bin/bash
#
# LXC chroot script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.
#

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
cat > /etc/apt/sources.list<<EOF
deb http://mirror.ovh.net/debian/ squeeze main contrib non-free
deb-src http://mirror.ovh.net/debian/ squeeze main contrib non-free

deb http://security.debian.org/ squeeze/updates main contrib non-free
deb-src http://security.debian.org/ squeeze/updates main contrib non-free

# Percona
#deb http://repo.percona.com/apt squeeze main
#deb-src http://repo.percona.com/apt squeeze main
EOF

gpg --keyserver  hkp://keys.gnupg.net --recv-keys 1C4CBDCDCD2EFD2A
gpg -a --export CD2EFD2A | apt-key add -

aptitude -q -y update
aptitude -q -y upgrade

# init.d
for FILE in bootlogd bootlogs bootmisc.sh checkfs.sh checkroot.sh halt hostname.sh hwclockfirst.sh hwclock.sh ifupdown ifupdown-clean killprocs module-init-tools mountall-bootclean.sh mountall.sh mountdevsubfs.sh mountkernfs.sh mountnfs-bootclean.sh mountnfs.sh mountoverflowtmp mtab.sh networking procps README reboot rmnologin rsyslog sendsigs single skeleton stop-bootlogd stop-bootlogd-single umountfs umountnfs.sh umountroot urandom                          
do
	update-rc.d -f $FILE remove
	rm -f -- /etc/init.d/$FILE
done

# /dev
aptitude -q -y purge udev
rm -rf /dev/.udev /etc/udev

mknod /dev/tty1 c 4 1 
mknod /dev/tty2 c 4 2
mknod /dev/tty3 c 4 3
mknod /dev/tty4 c 4 4

# inittab
cat > /etc/inittab<<EOF
# The default runlevel.
id:2:initdefault:

# Boot-time system configuration/initialization script.
# This is run first except when booting in emergency (-b) mode.
si::sysinit:/etc/init.d/rcS

# What to do in single-user mode.
~:S:wait:/sbin/sulogin

# /etc/init.d executes the S and K scripts upon change
# of runlevel.
#
# Runlevel 0 is halt.
# Runlevel 1 is single-user.
# Runlevels 2-5 are multi-user.
# Runlevel 6 is reboot.

l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
# Normally not reached, but fallthrough in case of emergency.
z6:6:respawn:/sbin/sulogin

# /sbin/getty invocations for the runlevels.
#
# The "id" field MUST be the same as the last
# characters of the device (after "tty").
#
# Format:
#  <id>:<runlevels>:<action>:<process>
#
# Note that on most Debian systems tty7 is used by the X Window System,
# so if you want to add more getty's go ahead but skip tty7 if you run X.
#

0:2345:respawn:/sbin/getty 38400 console
1:2345:respawn:/sbin/getty 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
3:23:respawn:/sbin/getty 38400 tty3
4:23:respawn:/sbin/getty 38400 tty4
EOF

# /etc/profile
cat >> /etc/profile <<EOF
# Set default locale
: ${LANG:=en_US.UTF-8}; export LANG
EOF

# /etc/rc.local
cat > /etc/rc.local<<EOF
#!/bin/bash -e
route add default gw 10.10.10.1
EOF

# /etc/resolv.conf
cat > /etc/resolv.conf<<EOF
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF

# Remove unused files and directories
rm -rf /home /media /mnt /opt /srv
rm -rf /var/log/*
rm -rf /etc/network
rm /etc/fstab /etc/hostname /etc/debian_version

# Install system packages
aptitude -q -y install locales vim htop less ssh screen dstat ifstat iotop ferm

# add ferm 
# add non-interactive mode

# Install user packages
aptitude -q -y install irssi 

# Set locale
perl -e 's/^# (en_US.UTF-8 UTF-8|pl_PL ISO-8859-2|pl_PL.UTF-8 UTF-8|de_DE.UTF-8 UTF-8)/$1/g' -p -i /etc/locale.gen
locale-gen
update-locale LANG=en_US LANGUAGE=$LANG LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Cleanup
aptitude clean
