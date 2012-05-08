#!/usr/bin/perl
#
# Snapshot config generator
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
use Data::Validate::Domain qw(is_domain);
use Smart::Comments;
$|++;

Readonly my $RSNAPSHOT_ROOT_DIR  => "/home/rsnapshot";
Readonly my $RSNAPSHOT_CONF_DIR  => "/etc/rsnapshot";
Readonly my $RSNAPSHOT_CONF_FILE => "$RSNAPSHOT_CONF_DIR/rsnapshot.conf";

Readonly my $SNAPSHOT_DIR        => "$RSNAPSHOT_ROOT_DIR/snapshots";
Readonly my $SNAPSHOT_CONF_DIR   => "$RSNAPSHOT_ROOT_DIR/snapshot.d";
Readonly my $SNAPSHOT_PREEXEC    => "$RSNAPSHOT_CONF_DIR/snapshot-preexec.pl";
Readonly my $SNAPSHOT_POSTEXEC   => "$RSNAPSHOT_CONF_DIR/snapshot-postexec.pl";

Readonly my $SSH_BIN             => '/usr/bin/ssh';
Readonly my $SSH_OPTIONS         => '-oStrictHostKeyChecking=no';
Readonly my $SSH_SNAPSHOT_USER   => 'root';
Readonly my $SSH_SNAPSHOT_PORT   => 22;
Readonly my $SSH_SNAPSHOT_KEY    => '/root/.ssh/snapshot_rsa';
Readonly my $SSH_RSYNC_USER      => 'root';
Readonly my $SSH_RSYNC_PORT      => 22;
Readonly my $SSH_RSYNC_KEY       => '/root/.ssh/rsync_rsa';

Readonly my $LVM_SNAPSHOT_COMMAND      => '/usr/local/sbin/lvm-snapshot';
Readonly my $LVM_SNAPSHOT_LIST_COMMAND => "$LVM_SNAPSHOT_COMMAND list ALL";
Readonly my $LVM_SNAPSHOT_DIR          => '/snapshot'; # Remote snapshot mount point

Readonly my $DEFAULT_LV_TYPE        => 'other';
Readonly my $DEFAULT_RETAIN_HOURLY  => 6;
Readonly my $DEFAULT_RETAIN_DAILY   => 7;
Readonly my $DEFAULT_RETAIN_WEEKLY  => 4;
Readonly my $DEFAULT_RETAIN_MONTHLY => 3;

Readonly my $BASENAME => basename($0);
Readonly my $USAGE    => <<END_OF_USAGE;
Snapshot config generator
	$BASENAME -h <hostname>

END_OF_USAGE

# Check paths
-d $RSNAPSHOT_ROOT_DIR     or die "Cannot find directory \$RSNAPSHOT_ROOT_DIR ($RSNAPSHOT_ROOT_DIR).\n";
-f $RSNAPSHOT_CONF_FILE    or die "Cannot find file \$RSNAPSHOT_CONF_FILE ($RSNAPSHOT_CONF_FILE).\n";
-f $SNAPSHOT_PREEXEC  or die "Cannot find file \$SNAPSHOT_PREEXEC ($SNAPSHOT_PREEXEC).\n";
-f $SNAPSHOT_POSTEXEC or die "Cannot find file \$SNAPSHOT_POSTEXEC ($SNAPSHOT_POSTEXEC).\n";

# Create directories
-d $SNAPSHOT_DIR or mkdir $SNAPSHOT_DIR, 0700
        or die "Cannot create directory \$SNAPSHOT_DIR ($SNAPSHOT_DIR)";
-d $SNAPSHOT_CONF_DIR or mkdir $SNAPSHOT_CONF_DIR, 0700
        or die "Cannot create directory \$SNAPSHOT_CONF_DIR ($SNAPSHOT_CONF_DIR)";

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

# Get logical volumes
my @lvs = `$SSH_BIN $SSH_OPTIONS -i $SSH_SNAPSHOT_KEY $SSH_SNAPSHOT_USER\@$ssh_host -p $SSH_SNAPSHOT_PORT $LVM_SNAPSHOT_LIST_COMMAND`;

LV:
foreach my $lv_name (@lvs) {
        chomp $lv_name;

        # Skip incorrect volume names
        next if $lv_name !~ /^[a-z0-9\-]+$/;
        next if $lv_name =~ /-snapshot$/;

        # Get container name and type from LV name
        my ($container_name, $container_type) = ($lv_name, $DEFAULT_LV_TYPE);
        if ($lv_name =~ /-/) {
                ($container_type, $container_name) = split /-/, $lv_name;
        }

        # Create snapshot configuration
        my $conf_file = "$SNAPSHOT_CONF_DIR/$container_type-$container_name.conf";
        open my $conf_fh, '>', $conf_file;
        print $conf_fh <<EOF;
# Snapshot configuration file
# container name: $container_name
# container type: $container_type

include_conf	$RSNAPSHOT_CONF_FILE
snapshot_root	$SNAPSHOT_DIR/$container_type/$container_name

ssh_args	$SSH_OPTIONS -i $SSH_RSYNC_KEY -p $SSH_RSYNC_PORT

retain	hourly	$retain_hourly
retain	daily	$retain_daily
retain	weekly	$retain_weekly
retain	monthly	$retain_monthly

cmd_preexec	$SNAPSHOT_PREEXEC -h $ssh_host create $lv_name
cmd_postexec	$SNAPSHOT_POSTEXEC -h $ssh_host remove $lv_name

backup	$SSH_RSYNC_USER\@$ssh_host:$SNAPSHOT_DIR/$container_name/	$container_name/
EOF
        close $conf_fh;
}
