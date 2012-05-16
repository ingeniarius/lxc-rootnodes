#!/bin/bash
set -e
cp vsftpd.conf /lxc/template/user/rootfs/etc/vsftpd.conf
cp vsftpd-conf.pl /lxc/template/user/rootfs/usr/local/sbin/vsftpd-conf
