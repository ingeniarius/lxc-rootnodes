#!/usr/bin/perl
#
# MySQL rsnapshot config generator
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use Readonly;
use Getopt::Long;
use File::Basename qw(basename);
use File::Path qw(remove_tree);
use Data::Validate::Domain qw(is_domain);
use Smart::Comments;
$|++;

Readonly my $RSNAPSHOT_ROOT_DIR  => "/home/rsnapshot";
Readonly my $RSNAPSHOT_CONF_DIR  => "/etc/rsnapshot";
Readonly my $RSNAPSHOT_CONF_FILE => "$RSNAPSHOT_CONF_DIR/rsnapshot.conf";

Readonly my $DB_DIR      => "$RSNAPSHOT_ROOT_DIR/mysqldumps";       # Rsnapshot destination directory
Readonly my $DB_CONF_DIR => "$RSNAPSHOT_ROOT_DIR/mysqldump.d";      # Rsnapshot configuration files 
Readonly my $DB_DUMP_DIR => "$RSNAPSHOT_ROOT_DIR/mysqldump_script"; # Temporary mysqldump directory 

Readonly my $MYSQL_BIN => "/usr/bin/mysql";

Readonly my $MYSQLDUMP_SCRIPT => "$RSNAPSHOT_CONF_DIR/mysqldump-script.pl"; # mysqldump script 
Readonly my $RSNAPSHOT_SCRIPT => "$DB_DUMP_DIR/mysqldump-script.pl";        # symlink to mysqldump script in dump directory

Readonly my $DEFAULT_CONTAINER_TYPE => 'other';
Readonly my $DEFAULT_RETAIN_HOURLY  => 6;
Readonly my $DEFAULT_RETAIN_DAILY   => 7;
Readonly my $DEFAULT_RETAIN_WEEKLY  => 4;
Readonly my $DEFAULT_RETAIN_MONTHLY => 3;

Readonly my %IS_SYSTEM_DB => (
	mysql => 1
);

Readonly my %IS_SKIPPED_DB => (
	information_schema => 1,
	performance_schema => 1,
);

Readonly my $BASENAME => basename($0);
Readonly my $USAGE    => <<END_OF_USAGE;
MySQLdump config generator
Usage:
	$BASENAME -h <hostname>

Script uses 127.0.0.1:3306 for MySQL connection.
SSH tunnel recommended (daemontools+autossh).

END_OF_USAGE

# Check paths
-d $RSNAPSHOT_ROOT_DIR  or die "Cannot find \$RSNAPSHOT_ROOT_DIR ($RSNAPSHOT_ROOT_DIR).\n";
-f $RSNAPSHOT_CONF_FILE or die "Cannot find \$RSNAPSHOT_CONF_FILE ($RSNAPSHOT_CONF_FILE).\n";
-f $MYSQLDUMP_SCRIPT    or die "Cannot find \$MYSQLDUMP_SCRIPT ($MYSQLDUMP_SCRIPT).\n";

# Recreate config directory
-d $DB_CONF_DIR and remove_tree($DB_CONF_DIR);
mkdir $DB_CONF_DIR, 0700 or die "Cannot create directory \$DB_CONF_DIR ($DB_CONF_DIR)";

# Create temporary dump directory
-d $DB_DUMP_DIR or mkdir $DB_DUMP_DIR, 0700 or die "Cannot create \$DB_DUMP_DIR ($DB_DUMP_DIR)";

# Create mysqldump-script symlink
-f $RSNAPSHOT_SCRIPT or symlink $MYSQLDUMP_SCRIPT, $RSNAPSHOT_SCRIPT;

# Create directories
-d $DB_DIR or mkdir $DB_DIR, 0700 or die "Cannot create directory \$DB_DIR ($DB_DIR)";

# Set default interval values
my $retain_hourly  = $DEFAULT_RETAIN_HOURLY;
my $retain_daily   = $DEFAULT_RETAIN_DAILY;
my $retain_weekly  = $DEFAULT_RETAIN_WEEKLY;
my $retain_monthly = $DEFAULT_RETAIN_MONTHLY;

# Show usage
die $USAGE if !@ARGV;

# Get options
my $ssh_host;
GetOptions(
        'host=s' => \$ssh_host
);

# Validate host
defined $ssh_host    or die "Host not specified.\n";
is_domain($ssh_host) or die "Host '$ssh_host' must be a domain.\n";

# Get database names
my @dbs = `$MYSQL_BIN -Nse 'show databases'`;

# Get databases
my (%user_db, @system_dbs, @other_dbs);

MYSQL_DB:
foreach my $db_name (@dbs) {
	chomp $db_name;

	my $is_system_db  = $IS_SYSTEM_DB{$db_name};
	my $is_skipped_db = $IS_SKIPPED_DB{$db_name};
	
	# Skip databases
	if ($is_skipped_db) {
		next MYSQL_DB;
	}

	# System databases
	if ($is_system_db) {
		push @system_dbs, $db_name;
		next MYSQL_DB;
	}	

	# User databases	
	if ($db_name =~ /^my(\d+)_\w+$/) {
		my $uid = $1;
		push @{ $user_db{$uid} }, $db_name;
		next MYSQL_DB;
	}

	# Other databases
	push @other_dbs, $db_name;
}

# Generate user configuration
foreach my $uid (sort keys %user_db) {
		
	# Config parameters
	my $container_name = $uid;
	my $container_type = 'user';
	my @user_dbs = @{ $user_db{$uid} };

	# Create config file
	generate_conf_file($container_name, $container_type, @user_dbs);
}

# Generate configuration for other types
generate_conf_file('mysql', 'system', @system_dbs) if @system_dbs;
generate_conf_file('mysql', 'other',  @other_dbs)  if @other_dbs;

sub generate_conf_file {
	my ($container_name, $container_type, @dbs) = @_;
	my $conf_file = "$DB_CONF_DIR/$container_type-$container_name.conf";
        open my $conf_fh, '>', $conf_file;
	print $conf_fh <<EOF;
# MySQL DB dump configuration file
# container name: $container_name
# container type: $container_type

include_conf	$RSNAPSHOT_CONF_FILE
snapshot_root	$DB_DIR/$container_type/$container_name

retain	hourly	$retain_hourly
retain	daily	$retain_daily
retain	weekly	$retain_weekly
retain	monthly	$retain_monthly

backup_script	$RSNAPSHOT_SCRIPT @dbs	mysql/
EOF
	close $conf_fh;
}
