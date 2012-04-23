#!/bin/bash
#
# Delete user script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

# show usage
usage() {
	echo "Usage: $0 <user_name>";
	exit 1
}

# necessary arguments
if [ $# -eq 1 ] 
then 
	user_name=$1
    uid=$2
else
	usage
fi

# satan
deluser_response=`/usr/bin/perl client.pl admin deluser $user_name`

# store response as arguments
set -- $deluser_response

# declare hash table
declare -A param

# iterate through key-value
while (( "$#" ))
do
    param["$1"]="$2"
    shift 2
done

# store variables
uid=${param['uid']}

# exit if no uid
if [ -z $uid ] 
then
    echo "No uid in deluser script"
    exit 1
fi

# lxc 
lxc stop $user_name
LVM_REMOVE=1 lxc remove $user_name

# proxy
proxy_service_dir="/lxc/system/proxy/rootfs/etc/service/$uid"
[ -d "$proxy_service_dir" ] && rm -r -- "$proxy_service_dir"
