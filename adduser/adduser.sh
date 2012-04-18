#!/bin/bash
#
# Adduser script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

# exit on error
set -e

# show usage
usage() {
	echo "Usage: $0 [ -u <uid> ] <user_name> <mail>";
	exit 1
}

# configuration
host='web1.rootnode.net'
type='web'
lvm_size='6G'

# optional arguments
while getopts 'u:' opt
do
	case "$opt" in
		u) uid=$OPTARG 
		   shift 2 ;;
	esac
done

# necessary arguments
if [ $# -eq 2 ] 
then 
	user_name=$1
	mail=$2
else
	usage
fi

# Satan::Admin
[ ! -z $uid ] && uid_param="uid $uid"
adduser_response=`satan admin adduser $user_name $uid_param`

# store response as arguments
set -- $adduser_response

# declare hash table
declare -A param

# iterate through key-value
while (( "$#" ))
do
	param["$1"]="$2"
	shift 2
done

# store variables
pam_passwd=${param['pam_passwd']}
pam_shadow=${param['pam_shadow']}
user_password=${param['user_password']}
user_password_p=${param['user_password_p']}
satan_key=${param['satan_key']}
uid=${param['uid']}

# create container
LVM_SIZE=$lvm_size lxc create $user_name $uid

# start container
lxc start $user_name

# copy /etc
cp -pvr /lxc/template/user/rootfs/home/etc /lxc/users/$user_name/rootfs/home/

# user directory
user_dir="/lxc/users/$user_name/rootfs/home/$user_name"
if [ ! -d $user_dir ]
then 
	mkdir $user_dir
	chmod 711 $user_dir
	chown $uid:$uid $user_dir
fi

# var/log
var_log_dir="/lxc/users/$user_name/rootfs/home/var/log"
rm -rf -- $var_log_dir/*
mkdir -- $var_log_dir/{apache2,nginx}

# satan user key
satan_dir="/lxc/users/$user_name/rootfs/home/etc/satan"
satan_key_file="$satan_dir/key"
[ ! -d "$satan_dir" ] && mkdir -- "$satan_dir"
chmod 711 -- "$satan_dir"

[ -e $satan_key_file ] && rm -- $satan_key_file
cat > $satan_key_file <<-EOF
	$uid $satan_key	
EOF

# satan proxy
proxy_service_dir="/lxc/system/proxy/rootfs/etc/service/$uid"
[ ! -d "$proxy_service_dir" ] && mkdir -- "$proxy_service_dir"
cat > "$proxy_service_dir/run" <<-EOF
	#!/bin/bash
	exec setuidgid satan ssh -oStrictHostKeyChecking=no -N -q -L $uid:localhost:999 satan@web1.rootnode.net -p $uid
EOF
chmod 755 -- "$proxy_service_dir/run"

# pam passwd
perl -i -pe "s/user=.+?-passwd/user=$uid-passwd/;
	     s/passwd=.+?\s/passwd=$pam_passwd /;" \
/lxc/users/$user_name/rootfs/home/etc/pam.d/common-{account,session}

# pam shadow
perl -i -pe "s/user=.+?-shadow/user=$uid-shadow/; 
             s/passwd=.+?\s/passwd=$pam_shadow /;" \
/lxc/users/$user_name/rootfs/home/etc/pam.d/common-{auth,password}

# nss passwd
perl -i -pe "s/^users\.db_user\s*=.*$/users.db_user = $uid-passwd;/;
             s/^users\.db_password\s*=.*$/users.db_password = $pam_passwd;/;" \
/lxc/users/$user_name/rootfs/home/etc/nss-mysql.conf

# nss shadow
perl -i -pe "s/^shadow\.db_user\s*=.*$/shadow.db_user = $uid-shadow;/;
             s/^shadow\.db_password\s*=.*$/shadow.db_password = $pam_shadow;/;" \
/lxc/users/$user_name/rootfs/home/etc/nss-mysql-root.conf

# permissions and owner for apache2 and nginx files
find /lxc/users/$user_name/rootfs/home/etc/{apache2,nginx} -type d | xargs -i chmod 700 {}
find /lxc/users/$user_name/rootfs/home/etc/{apache2,nginx} -type f | xargs -i chmod 600 {}
chown -h -R $uid:$uid /lxc/users/$user_name/rootfs/home/etc/{apache2,nginx}

# nginx user.conf
nginx_user_conf_file="/lxc/users/$user_name/rootfs/home/etc/nginx/user.conf"
[ -e "$nginx_user_conf_file" ] && rm -- "$nginx_user_conf_file"
cat > $nginx_user_conf_file <<-EOF
	user $user_name $user_name;
EOF

# lxc information (ip address, uid, username, type)
lxc_dir="/lxc/users/$user_name/rootfs/home/etc/lxc"
ipaddr=$(lxc ip $uid)
[ ! -d "$lxc_dir" ] && mkdir -- "$lxc_dir"

for FILE in uid user ipaddr type 
do
	[ -e "$lxc_dir/$FILE" ]  && rm -- "$lxc_dir/$FILE"
done
echo $uid       > "$lxc_dir/uid"
echo $user_name > "$lxc_dir/user"
echo $ipaddr    > "$lxc_dir/ipaddr"
echo $type      > "$lxc_dir/type"

# firewall
ipaddr=`lxc ip $uid`
cat > /etc/ferm/ferm.d/$uid <<-EOF
	table filter {
		chain FORWARD {
			proto tcp destination $ipaddr dport 22 ACCEPT;
			proto tcp destination $ipaddr dport 80 ACCEPT;
		}
	}

	table nat {
		chain PREROUTING {
			proto tcp destination 176.31.234.143 dport $uid DNAT to $ipaddr:22;
			proto tcp destination 176.31.234.143 dport 1$uid DNAT to $ipaddr:80;
		}
	}
EOF
/etc/init.d/ferm reload

# send e-mail
/usr/bin/perl mail.pl -l pl -f templates/adduser.tmpl -t $mail user_name=$user_name user_password="$user_password $user_password_p" port=$uid host=$host 
