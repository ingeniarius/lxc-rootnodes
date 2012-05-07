#!/usr/bin/perl
#
# Rsnapshot cron script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use Readonly;
use Getopt::Long;
use POSIX qw(isdigit);
use File::Basename qw(basename);
use Data::Validate::Domain qw(is_domain);
use Smart::Comments;

# Configuration
Readonly my $SSH_PORT    => 22;
Readonly my $SSH_USER    => 'root';
Readonly my $SSH_BIN     => '/usr/bin/ssh';
Readonly my $SSH_OPTIONS => '-oStrictHostKeyChecking=no';

Readonly my $LVM_SNAPSHOT_DIR     => '/snapshot'; # Snapshot mount point
Readonly my $LVM_SNAPSHOT_COMMAND => '/usr/local/sbin/lvm-snapshot';
Readonly my $LVM_SNAPSHOT_SUFFIX  => 'snapshot';

Readonly my $RSNAPSHOT_BIN       => '/usr/bin/rsnapshot';
Readonly my $RSNAPSHOT_DIR       => '/etc/rsnapshot';
Readonly my $RSNAPSHOT_MAIN_CONF => "$RSNAPSHOT_DIR/rsnapshot.conf";
Readonly my $RSNAPSHOT_ROOT_DIR  => '/home/rsnapshot';
Readonly my $RSNAPSHOT_USER_CONF => "$RSNAPSHOT_ROOT_DIR/user.conf";
Readonly my $RSNAPSHOT_DU_DIR    => "$RSNAPSHOT_ROOT_DIR/du_reports";

Readonly my $DEFAULT_RETAIN_HOURLY  => 6;
Readonly my $DEFAULT_RETAIN_DAILY   => 7;
Readonly my $DEFAULT_RETAIN_WEEKLY  => 4;
Readonly my $DEFAULT_RETAIN_MONTHLY => 3;
Readonly my $DEFAULT_LV_TYPE        => 'other';

-f $RSNAPSHOT_MAIN_CONF or die "Configuration file \$RSNAPSHOT_MAIN_CONF ($RSNAPSHOT_MAIN_CONF) not found.\n";
-d $RSNAPSHOT_ROOT_DIR  or die "Root directory \$RSNAPSHOT_ROOT_DIR ($RSNAPSHOT_ROOT_DIR) not found.\n";

Readonly my $BASENAME => basename($0);
Readonly my $USAGE    => <<END_OF_USAGE;
Rsnapshot cron script
Usage: 
	$BASENAME [OPTIONS] <backup_level>

Available backup levels are: hourly, daily, weekly, monthly
Options:
	--host         connection host (required)
	--user         remote user name
	--port         connection port
	--command      LVM snapshot command

END_OF_USAGE

# Remove old user configuration
unlink $RSNAPSHOT_USER_CONF;

# Create du reports directory
-d $RSNAPSHOT_DU_DIR or mkdir $RSNAPSHOT_DU_DIR, 0700;

# Set default SSH values
my $ssh_port    = $SSH_PORT;
my $ssh_user    = $SSH_USER;
my $ssh_command = $LVM_SNAPSHOT_COMMAND;
my $ssh_host;

# Set default interval values
my $retain_hourly  = $DEFAULT_RETAIN_HOURLY;
my $retain_daily   = $DEFAULT_RETAIN_DAILY;
my $retain_weekly  = $DEFAULT_RETAIN_WEEKLY;
my $retain_monthly = $DEFAULT_RETAIN_MONTHLY;

# Get options
GetOptions(
	'port=i'     => \$ssh_port,
	'user=s'     => \$ssh_user,
	'host=s'     => \$ssh_host,
	'command=s'  => \$ssh_command,
);

# Get arguments
my $backup_level = shift or die $USAGE;

# Validate SSH 
isdigit($ssh_port)                     or die "SSH port '$ssh_port' must be a number.\n";
($ssh_port > 0 and $ssh_port <= 65535) or die "SSH port '$ssh_port' must be between 1 and 65535.\n";

# Validate SSH user
$ssh_user =~ /^[a-z0-9]{2,32}$/ or die "Incorrect SSH user '$ssh_user'.\n";

# Validate SSH host
defined $ssh_host    or die "Host not specified.\n";
is_domain($ssh_host) or die "Host '$ssh_host' must be a domain.\n";

# Get logical volumes
my @lvs = `$SSH_BIN $SSH_OPTIONS $ssh_user\@$ssh_host -p $ssh_port $ssh_command list ALL`;

BACKUP:
foreach my $lv_name (@lvs) {
	chomp $lv_name;
	
	# Skip incorrect volume names
	next if $lv_name !~ /^[a-z0-9\-]+$/;

	# Get container name and type from LV name
	# Container type is undef if LV name not hyphened
	my ($container_name, $container_type) = ($lv_name, $DEFAULT_LV_TYPE);
	if ($lv_name =~ /-/) {
		($container_type, $container_name) = split /-/, $lv_name;
	}

	# Create user configuration	
	create_user_conf($container_name, $container_type);

	# Create LVM snapshot
	lvm_snapshot('create', $lv_name);
			
	# Run rsnapshot
	system("$RSNAPSHOT_BIN -c $RSNAPSHOT_USER_CONF $backup_level");

	# Remove LVM snapshot
	lvm_snapshot('remove', $lv_name);

	# Generate size report
	generate_du_report($container_name, $container_type);
}

exit 0;

sub generate_du_report {
	my ($container_name, $container_type) = @_;
	
	# Du report directory
	my $du_report_dir = "$RSNAPSHOT_DU_DIR/$container_type";
	if (!-d $du_report_dir) {
		mkdir $du_report_dir or die "Cannot create du report directory '$du_report_dir'"; 
	}
 	
	# Generate du report
	my $du_report = `$RSNAPSHOT_BIN -c $RSNAPSHOT_USER_CONF du`;
	
	# Remove old report file
	my $du_report_file = "$du_report_dir/$container_name";
	unlink $du_report_file;
	
	# Save report
	open my $du_report_fh, '>', $du_report_file;
	print $du_report_fh $du_report;
	close $du_report_fh;

	return;
}

sub create_user_conf {
	my ($container_name, $container_type) = @_;

	# Destination path
	my $snapshot_root = "$RSNAPSHOT_ROOT_DIR/$container_type/$container_name";

	# Create user configuration file
	open my $conf_fh, '>', $RSNAPSHOT_USER_CONF or die "Cannot create $RSNAPSHOT_USER_CONF file";
	print $conf_fh <<EOF;
# Config file for $container_name
include_conf	$RSNAPSHOT_MAIN_CONF
snapshot_root	$snapshot_root

ssh_args	-p $ssh_port $SSH_OPTIONS

retain	hourly	$retain_hourly
retain	daily	$retain_daily
retain	weekly	$retain_weekly
retain	monthly	$retain_monthly

backup	$ssh_user\@$ssh_host:$LVM_SNAPSHOT_DIR/$container_name/	$container_name/
EOF
	close $conf_fh;
	return;
}

sub lvm_snapshot {
	my ($command_name, $lv_name) = @_;

	# Create remote LVM snapshot
	system("$SSH_BIN $SSH_OPTIONS $ssh_user\@$ssh_host -p $ssh_port $ssh_command $command_name $lv_name");
	return;
}
