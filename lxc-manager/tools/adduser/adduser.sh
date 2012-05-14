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
mailhub=10.1.0.11

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
adduser_response=`/usr/bin/perl client.pl admin adduser $user_name $uid_param`

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
cp -pvr /lxc/template/user/rootfs/home/etc /lxc/user/$user_name/rootfs/home/

# user directory
user_dir="/lxc/user/$user_name/rootfs/home/$user_name"
if [ ! -d $user_dir ]
then 
	mkdir $user_dir
	mkdir $user_dir/etc
	ln -s /etc/apache2 $user_dir/etc/apache2
	ln -s /etc/nginx $user_dir/etc/nginx
	chmod 711 $user_dir
	chown $uid:$uid $user_dir
fi

# var/log
var_log_dir="/lxc/user/$user_name/rootfs/home/var/log"
rm -rf -- $var_log_dir/*
mkdir -- $var_log_dir/{apache2,nginx}

# satan user key
satan_dir="/lxc/user/$user_name/rootfs/home/etc/satan"
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
/lxc/user/$user_name/rootfs/home/etc/pam.d/common-{account,session}

# pam shadow
perl -i -pe "s/user=.+?-shadow/user=$uid-shadow/; 
             s/passwd=.+?\s/passwd=$pam_shadow /;" \
/lxc/user/$user_name/rootfs/home/etc/pam.d/common-{auth,password}

# nss passwd
perl -i -pe "s/^users\.db_user\s*=.*$/users.db_user = $uid-passwd;/;
             s/^users\.db_password\s*=.*$/users.db_password = $pam_passwd;/;" \
/lxc/user/$user_name/rootfs/home/etc/nss-mysql.conf

# nss shadow
perl -i -pe "s/^shadow\.db_user\s*=.*$/shadow.db_user = $uid-shadow;/;
             s/^shadow\.db_password\s*=.*$/shadow.db_password = $pam_shadow;/;" \
/lxc/user/$user_name/rootfs/home/etc/nss-mysql-root.conf

# permissions and owner for apache2 and nginx files
find /lxc/user/$user_name/rootfs/home/etc/{apache2,nginx} -type d | xargs -i chmod 700 {}
find /lxc/user/$user_name/rootfs/home/etc/{apache2,nginx} -type f | xargs -i chmod 600 {}
chown -h -R $uid:$uid /lxc/user/$user_name/rootfs/home/etc/{apache2,nginx}

# nginx user.conf
nginx_user_conf_file="/lxc/user/$user_name/rootfs/home/etc/nginx/user.conf"
[ -e "$nginx_user_conf_file" ] && rm -- "$nginx_user_conf_file"
cat > $nginx_user_conf_file <<-EOF
	user $user_name $user_name;
EOF

# lxc information (ip address, uid, username, type)
lxc_dir="/lxc/user/$user_name/rootfs/home/etc/lxc"
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

# ssmtp
ssmtp_file="/lxc/user/$user_name/rootfs/home/etc/ssmtp/ssmtp.conf"
[ -e "$ssmtp_file" ] && rm -- "$ssmtp_file"
cat > $ssmtp_file <<-EOF
	#
	# Config file for sSMTP sendmail
	#
	# The person who gets all mail for userids < 1000
	# Make this empty to disable rewriting.
	root=postmaster

	# The place where the mail goes. The actual machine name is required no 
	# MX records are consulted. Commonly mailhosts are named mail.domain.com
	mailhub=$mailhub

	# Where will the mail seem to come from?
	#rewriteDomain=

	# The full hostname
	hostname=$type.$user_name.rootnode.net

	# Are users allowed to set their own From: address?
	# YES - Allow the user to specify their own From: address
	# NO - Use the system generated From: address
	FromLineOverride=YES
EOF

# firewall
ipaddr=`lxc ip $uid`
cat > /etc/ferm/ferm.d/$uid <<EOF
table filter {
	chain FORWARD {
		proto tcp destination $ipaddr dport 22 ACCEPT;
		proto tcp destination $ipaddr dport 8080 ACCEPT;
		proto tcp destination $ipaddr dport ${uid}0:${uid}9 ACCEPT;
	}
}

table nat {
	chain PREROUTING {
		proto tcp destination \$PUBLIC_IP dport $uid DNAT to $ipaddr:22;
		#proto tcp destination \$PUBLIC_IP dport 1$uid DNAT to $ipaddr:80;
		proto tcp destination \$PUBLIC_IP dport ${uid}0:${uid}9 DNAT to $ipaddr:${uid}0-${uid}9;
	}
}
EOF
/etc/init.d/ferm reload

# send e-mail
cd ../mail
/usr/bin/perl mail.pl -l pl -f templates/adduser.tmpl -t $mail user_name=$user_name user_password="$user_password $user_password_p" port=$uid host=$host 
