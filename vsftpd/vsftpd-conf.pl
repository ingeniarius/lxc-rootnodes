#!/usr/bin/perl
#
# Vsftpd user conf generator
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use DBI;
use Readonly;

# Configuration
Readonly my $DB_HOST         => '10.1.0.12';
Readonly my $DB_PORT         => '3306';
Readonly my $DB_NAME         => 'ftp';
Readonly my $VSFTPD_PAM_FILE => '/etc/pam.d/vsftpd';
Readonly my $VSFTPD_USER_DIR => '/etc/vsftpd/users';
Readonly my $VSFTPD_LINK_DIR => '/home/ftp';
Readonly my $LXC_UID_FILE    => '/etc/lxc/uid';
Readonly my $LXC_SERVER_FILE => '/etc/lxc/server'; 
Readonly my $LXC_USER_FILE   => '/etc/lxc/user';

$|++;
umask 0077;

# Check paths
-f $VSFTPD_PAM_FILE or die "Vsftpd pam file \$VSFTPD_PAM_FILE ($VSFTPD_PAM_FILE) not found.\n";
-d $VSFTPD_USER_DIR or die "Vsftpd user directory \$VSFTPD_USER_DIR ($VSFTPD_USER_DIR) not found.\n";
-d $VSFTPD_LINK_DIR or die "Vsftpd link directory \$VSFTPD_LINK_DIR ($VSFTPD_LINK_DIR) not found.\n";

# Get UID
open my $uid_fh, '<', $LXC_UID_FILE or die "Cannot open $LXC_UID_FILE file: $!\n";
my $uid = <$uid_fh>;
chomp $uid;
close $uid_fh;

# Get user name
open my $user_fh, '<', $LXC_USER_FILE or die "Cannot open $LXC_USER_FILE file: $!\n";
my $user = <$user_fh>;
chomp $user;
close $user_fh;

# Get server name
open my $server_fh, '<', $LXC_SERVER_FILE or die "Cannot open $LXC_SERVER_FILE file: $!\n";
my $server_name = <$server_fh>;
chomp $server_name;
close $server_fh;

# Open vsftpd pam file
open my $pam_vsftpd_fh, '<', $VSFTPD_PAM_FILE or die "Cannot open $VSFTPD_PAM_FILE file: $!\n";
my @pam_vsftpd = <$pam_vsftpd_fh>;
close $pam_vsftpd_fh;

# Get database credentials
my ($db_user, $db_password);
for (@pam_vsftpd) {
	chomp;
	if (/^auth.+\s+user=([a-z0-9-]+?)\s+passwd=(\w+?)\s/) {
		$db_user     = $1;
		$db_password = $2;
		last;
	}
}

# Credentials not found
defined($db_user and $db_password) or die "Cannot find vsftpd database user and password.\n";
#$db_user eq "$user-ftp"            or die "Incorrect LXC user '$user'.\n";

# Connect to database
my $dbh = DBI->connect("dbi:mysql:$DB_NAME:$DB_HOST:$DB_PORT", $db_user, $db_password, { RaiseError => 1, AutoCommit => 1});

# Get symlinks
my @symlink_list = glob("$VSFTPD_LINK_DIR/*");
my %is_orphaned = map { $_ => 1 } @symlink_list;

# Get users
my $get_users = $dbh->prepare("SELECT user_name, directory, mkdir_priv, delete_priv, upload_priv, read_priv, ssl_priv FROM users WHERE uid=? AND server_name=?"); 
$get_users->execute($uid, $server_name);
while( my($user_name, $directory, $mkdir_priv, $delete_priv, $upload_priv, $read_priv, $ssl_priv) = $get_users->fetchrow_array ) {
	# Check directory
	$directory =~ /^\//           or die "Directory '$directory' for FTP account '$user_name' must be an absolute path.\n";	
	-d $directory                 or die "Directory '$directory' for FTP account '$user_name' not found.\n";
        (stat($directory))[4] == $uid or die "Cannot create FTP account '$user_name'. Not an owner of directory '$directory'.\n";

	# Set privileges
	$mkdir_priv  = $mkdir_priv  ? 'YES' : 'NO';
	$delete_priv = $delete_priv ? 'YES' : 'NO';
	$upload_priv = $upload_priv ? 'YES' : 'NO';
	$read_priv   = $read_priv   ? 'NO'  : 'YES'; # Invert priv here! 
	$ssl_priv    = $ssl_priv    ? 'YES' : 'NO';

	# Save file
	my $file_name = "$VSFTPD_USER_DIR/$user_name";
	open my $file_fh, '>', $file_name or die "Cannot open user file $file_name: $!\n";
	print $file_fh <<EOF;
pasv_min_port=${uid}1
pasv_max_port=${uid}9
anon_mkdir_write_enable=$mkdir_priv
anon_other_write_enable=$delete_priv
anon_upload_enable=$upload_priv
anon_world_readable_only=$read_priv
force_anon_data_ssl=$ssl_priv
force_anon_logins_ssl=$ssl_priv
EOF
	close $file_fh;

	# Create symlink
	my $symlink_file = "$VSFTPD_LINK_DIR/$user_name";
	unlink $symlink_file;
	delete $is_orphaned{$symlink_file};
	symlink "$directory", "$symlink_file" or die "Cannot create symlink '$symlink_file' pointing to '$directory'\n";
}

# Remove old symlinks
foreach my $symlink (keys %is_orphaned) {
	next unless -d $symlink; # skip if not directory
	next unless -l $symlink; # skip if not symlink
	unlink $symlink;
}

# Run vsftpd
# exec /usr/sbin/vsftpd /etc/vsftpd.conf -oguest_username=$user
