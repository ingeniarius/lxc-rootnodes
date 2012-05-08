#!/usr/bin/perl
#
# Snapshot preexec/postexec script
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

# Configuration
Readonly my $SSH_BIN     => '/usr/bin/ssh';
Readonly my $SSH_USER    => 'root';
Readonly my $SSH_PORT    => 22;
Readonly my $SSH_KEY     => '/root/.ssh/snapshot_rsa';
Readonly my $SSH_OPTIONS => '-oStrictHostKeyChecking=no';
Readonly my $SSH_COMMAND => '/usr/local/sbin/lvm-snapshot';

Readonly my $BASENAME => basename($0);
Readonly my $USAGE    => <<END_OF_USAGE;
Snapshot preexec script
	$BASENAME -h <hostname> create|remove <lv_name>

END_OF_USAGE

# Get options
my $ssh_host;
GetOptions(
        'host=s' => \$ssh_host
);

# Get command name
my $command_name = shift or die $USAGE;
   $command_name =~ /^(?:create|remove)$/ or die "No such command '$command_name'. See '$BASENAME help'.\n";

my $lv_name = shift or die $USAGE;
   $lv_name =~ /^[a-z0-9\-]+$/ or die "Incorrect LV name '$lv_name'\n";

# Validate host
defined $ssh_host    or die "Host not specified.\n";
is_domain($ssh_host) or die "Host '$ssh_host' must be a domain.\n";

# Create remote LVM snapshot
system("$SSH_BIN $SSH_OPTIONS -i $SSH_KEY $SSH_USER\@$ssh_host -p $SSH_PORT $SSH_COMMAND $command_name $lv_name");
die $! if $?;

exit 0;
