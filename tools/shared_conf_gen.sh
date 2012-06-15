#!/bin/bash
#
# Create/Update structure for symlinked configuration
# Rootnode http://rootnode.net
# 
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

umask 0077

# arguments
SRC=$1
DST=$2
TYPE=$3

# show usage
if [ -z $SRC ] || [ -z $DST ] || [ ! -d $SRC ]
then
	echo "Usage: $0 <source dir> <destination dir>"
	exit 1
fi

# make absolute paths
SRC=$(readlink -f $SRC)
DST=$(readlink -f $DST)

# create destination directory
[ ! -d $DST ] && mkdir $DST

# define grep regexp
case $TYPE in
	apache2|nginx) REGEXP="^$SRC/(mod|site)-enabled/";;
	*)             REGEXP="^$";;
esac

# recreate directory structure
find $SRC/* -type d | sed s:$SRC/:: | grep -vE $REGEXP | xargs -i mkdir -p $DST/{}

# copy regular files as symlinks
find $SRC/* -type f | sed s:$SRC/:: | grep -vE $REGEXP | xargs -i cp -ps $SRC/{} $DST/{}

# copy symlinks
find $SRC/* -type l | sed s:$SRC/:: | grep -vE $REGEXP | xargs -i cp -pr $SRC/{} $DST/{}
