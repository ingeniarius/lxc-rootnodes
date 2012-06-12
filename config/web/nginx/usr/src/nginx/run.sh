#!/bin/bash
# 
# Nginx compilation script
# for proxy container
#
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

# Die on error
set -e

usage() {
        basename=$(basename $0)
        echo "Usage: $basename <nginx_dir>"
        exit 1
}

NGINX_DIR=$1
[   -z $NGINX_DIR ] && usage
[ ! -d $NGINX_DIR ] && usage

cd $NGINX_DIR
./configure \
        --prefix=/usr/local/nginx \
        --pid-path=/var/run/nginx/nginx.pid \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --with-http_ssl_module \
        --user=www-data \
        --group=www-data
