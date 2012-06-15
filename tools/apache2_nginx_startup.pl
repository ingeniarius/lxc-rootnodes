#!/usr/bin/perl
#
# Apache2/Nginx startup script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use Readonly;
use File::Basename qw(basename);
use Smart::Comments;

Readonly my $NGINX_BIN      => '/usr/sbin/nginx';
Readonly my $APACHE2CTL_BIN => '/usr/sbin/apache2ctl';

Readonly my $BASENAME => basename($0);
Readonly my $USAGE => <<END_OF_USAGE;
Apache2/Nginx startup script

Apache2 and Nginx daemons are managed by daemontools keeping
them always running. This script checks configuration 
and kills web server processes.

\033[1mUsage:\033[0m $BASENAME restart

END_OF_USAGE

# Get service name (apache2 or nginx)
my $service_name = $BASENAME;
if ($service_name ne 'apache2' and $service_name ne 'nginx') {
	die "Unknown service name '$service_name'.\nSymlink to this script binary should be named apache2 or nginx.\n";
}

# Get command name from command line
my $command_name = shift or usage();
   $command_name eq 'help' and usage();

if (not defined $main::{$command_name}) {
        die "Command '$command_name' not found. See '$BASENAME help'.\n";
}

#eval "$command_name(\@container_params)";
eval $command_name;
die $@ if $@;

sub restart {
	# Start apache2
	if ($service_name eq 'apache2') {

		# Test configuration
		`$APACHE2CTL_BIN -t`;
		$? and exit 1;

		# Kill running processes
		`pkill -o ^apache2\$`;
	}

	# Start nginx
	if ($service_name eq 'nginx') {

		# Test configuration
		`$NGINX_BIN -t`;
		$? and exit 1;

		# Kill running processes
		`pkill -o ^nginx\$`;
	}
	
	# Show information
	print "Service '$service_name' restarted.\n";
	exit;
}

sub usage {
	print $USAGE;
	exit;
}
