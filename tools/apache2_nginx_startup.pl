#!/usr/bin/perl
#
# Apache2 & Nginx init script
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
Apache2 & Nginx init script
\033[1mUsage:\033[0m 
	apache2 start|stop|restart
	nginx   start|stop|restart

END_OF_USAGE

# Check files
-f $NGINX_BIN      or die "\$NGINX_BIN ($NGINX_BIN) not found. Cannot proceed.\n";
-f $APACHE2CTL_BIN or die "\$APACHE2CTL_BIN ($APACHE2CTL_BIN) not found. Cannot proceed.\n";

# Get service name (apache2 or nginx)
my $server_type = $BASENAME;
if ($server_type ne 'apache2' and $server_type ne 'nginx') {
	die "Unknown service name '$server_type'.\nSymlink to this script binary should be named apache2 or nginx.\n";
}

# Get command name from command line
my $command_name = shift or usage();
   $command_name eq 'help' and usage();

if (not defined $main::{$command_name}) {
        die "Command '$command_name' not found. See '$BASENAME help'.\n";
}

# Run subroutine
eval "$command_name(\$server_type)";
die $@ if $@;

sub test_config {
	my ($server_type) = @_;

	# Test configuration
	my $test_result;
	$test_result = `$APACHE2CTL_BIN -t 2>&1` if $server_type eq 'apache2';
	$test_result = `$NGINX_BIN -t 2>&1`      if $server_type eq 'nginx';
	chomp $test_result;
	
	# Return results if test failed
	return $test_result if $?;
	return;
}

sub check_procs {
	# Get number of running processes with pgrep command
	my ($server_type) = @_;
	my $number_of_procs = `pgrep -c ^$server_type\$`;
	chomp $number_of_procs;
	return $number_of_procs;
}

sub restart {
	# Run stop and start
	my ($server_type) = @_;
	stop($server_type);
	start($server_type);
	exit;
}

sub status {
	# Show server status
	my ($server_type) = @_;
	my $server_is_running = check_procs($server_type);
	if ($server_is_running) {
		print "$server_type is running.\n";
		exit;
	} 
	die "$server_type is NOT running.\n";
}

sub test {
	# Test server configuration
	my ($server_type) = @_;
	my $test_result = test_config($server_type);
	
	# Test failed
	if (defined $test_result) {
		die "$test_result\n";
		
	}

	# Test OK
	print "OK\n";
	exit;
}

sub stop {
	my ($server_type) = @_;
	
	# Print information
	print "Stopping $server_type...";

	# Check web server process
	my $server_is_running = check_procs($server_type);
	if (! $server_is_running) {
		print " not running\n";
		exit;
	}

	# Stop web server
	my $stop_command;
	   $stop_command = "$APACHE2CTL_BIN stop" if $server_type eq 'apache2';
	   $stop_command = "pkill ^nginx\$"       if $server_type eq 'nginx';
	
	system($stop_command);
	if ($?) {
		print "failed!\n";
		die "Reason: $!\n";
	}

	sleep 2;
	my $server_still_running = check_procs($server_type);
	if ($server_still_running) {
		system("pkill -9 ^$server_type\$");
		print "cannot stop, server killed with kill -9\n";
		exit;
	}
	
	print "done\n";
	exit;
}

sub start {
	my ($server_type) = @_;
		
	# Print information
	print "Starting $server_type...";

	# Check web server process
	my $number_of_procs = `pgrep -c ^$server_type\$`;
	chomp $number_of_procs;
	if ($number_of_procs) {
		print " already running\n";
		exit;
	}

	# Check configuration
	my $test_result = test_config($server_type);
	if (defined $test_result) {
		print "failed!\n";
		die "$test_result\n";
	}

	# Start web server
	my $start_command;
	   $start_command = "$APACHE2CTL_BIN start" if $server_type eq 'apache2';
	   $start_command = "$NGINX_BIN"            if $server_type eq 'nginx';
	
	system($start_command);
	if ($?) {
		print "failed!\n";
		die "Reason: $!\n";
	}

	print "done\n";
	exit;
}

sub usage {
	print $USAGE;
	exit;
}
