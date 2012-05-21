#!/bin/bash

set -e
host='10.1.0.12'
user_name=$1
if [ -z "$user_name" ] 
then
	echo "User name not specified."
	exit 1
fi

uid=`cat /lxc/user/$user_name/id`
password=`apg -a 0 -n 1 -m 12 -x 16 -M NCL`
pam_file="/lxc/user/$user_name/rootfs/home/etc/pam.d/vsftpd"

cp -v /lxc/repo/libpam-mysql/pam.d/vsftpd $pam_file

perl -i -pe "s/user=.+?-ftp\s/user=$uid-ftp /" $pam_file
perl -i -pe "s/passwd=.+?\s/passwd=$password /" $pam_file
perl -i -pe "s/host=.+?\s/host=$host /" $pam_file

ssh $host "mysql -Nse \"GRANT SELECT ON ftp.users TO '$uid-ftp' IDENTIFIED BY '$password'\""
ssh $host "mysql -Nse \"FLUSH PRIVILEGES\""
