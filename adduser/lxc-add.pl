#!/usr/bin/perl -l
#
# lxc-add 
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use File::Basename qw(basename);
use YAML;
use Readonly;
use FindBin qw($Bin);
use List::MoreUtils qw(uniq);
use Data::Validate::IP qw(is_ipv4);
use Smart::Comments;
use Getopt::Long;

Readonly my $CONFIG_FILE => '/lxc/repo/adduser/config.yaml';
Readonly my $SCRIPT_DIR  => '/lxc/repo/adduser/adduser.d';
Readonly my $LXC_BIN     => '/usr/local/sbin/lxc';

my $config = YAML::LoadFile($CONFIG_FILE);
### $config

# Usage
Readonly my $BASENAME => basename($0);
Readonly my $USAGE => <<END_OF_USAGE;
lxc-add script
Usage:
	$BASENAME [ <key> <value> ]...
END_OF_USAGE

# Get arguments
if (@ARGV % 2) {
	die "Uneven number of arguments. Cannot proceed.\n";
}
my %arg = @ARGV;
### %arg

# Get server info
my %server_info;
foreach my $info_type (qw(type id no)) {
	my $server_info = `$LXC_BIN $info_type` or die "Cannot get server info '$info_type'";
	chomp $server_info;
	$server_info{$info_type} = $server_info;
}
my $server_info_args = join ' ', map { "server_$_ $server_info{$_}" } keys %server_info;

sub get_config_scripts { 
	# Server config 
	my $server_type = $server_info{type};

	# Check if config exists
	defined $config->{$server_type} or die "Server type '$server_type' not found in config.\n";

	# Get script names from default config and server config
	my $default_scripts = $config->{default}->{scripts};
	my $server_scripts = $config->{$server_type}->{scripts};

	# Merge lists together and remove duplicates
	my @script_names = uniq( @$default_scripts, @$server_scripts );

	return @script_names;
}

sub get_config_param {
	my ($param_name) = @_;

	# Get server specific param or default param
	my $server_type = $server_info{type};
	my $param = $config->{$server_type}->{params}->{$param_name} || $config->{default}->{params}->{$param_name};

	return $param;
}

# Get arguments
my $uid        = $arg{uid}        or die "Uid not specified.\n";
my $user_name  = $arg{user_name}  or die "Username not specified.\n";
my $satan_key  = $arg{satan_key}  or die "Satan key not specified.\n";
my $pam_passwd = $arg{pam_passwd} or die "Pam passwd not specified.\n";
my $pam_shadow = $arg{pam_shadow} or die "Pam shadow not specified.\n";

# LVM parameters
my $lvm_size   = get_config_param('lvm_size');

# SSMTP host
my $ssmtp_id   = get_config_param('ssmtp_id');
my $ssmtp_host = "10.$server_info{id}.0.$ssmtp_id";
is_ipv4($ssmtp_host) or die "Cannot get SSMTP host";

# Vsftpd host
my $vsftpd_id   = get_config_param('vsftpd_id');
my $vsftpd_host = "10.$server_info{id}.0.$vsftpd_id"; 
is_ipv4($vsftpd_host) or die "Cannot get Vsftpd host";

# User IP address
my $ipaddr = `$LXC_BIN ip $uid` or die "Cannot get IP address for uid $uid";
chomp $ipaddr;

# Arguments for adduser.d scripts
my @command_args;
push @command_args, "user_name $user_name";      # User name
push @command_args, "uid $uid";                  # Uid
push @command_args, "ipaddr $ipaddr";            # IP address

push @command_args, "satan_key $satan_key";      # Satan client key
push @command_args, "pam_passwd $pam_passwd";    # NSS shadow
push @command_args, "pam_shadow $pam_shadow";    # NSS passwd

push @command_args, "ssmtp_host $ssmtp_host";    # SSMTP host
push @command_args, "vsftpd_host $vsftpd_host";  # Vsftpd host

push @command_args, $server_info_args;           # Server info

# Store arguments as string
chomp @command_args;
my $command_args = join ' ', @command_args;

# Create container
system("LVM_SIZE=$lvm_size $LXC_BIN create $user_name $uid");
if ($?) {
	die "Cannot create container '$user_name': $!\n";
}

# Start container
system("$LXC_BIN start $user_name");
if ($?) {
	die "Cannot start container '$user_name': $!\n";
}

# Get adduser.d scripts
my @script_names = get_config_scripts();

# Run scripts
foreach my $script_name (@script_names) {
	print "Running $script_name...";

	# Check task script
	my $script_file = "$SCRIPT_DIR/$script_name";
	-f $script_file or die "Script '$script_name' not found.\n";
	
	# Run script
	system("$script_file $command_args");
	if ($?) {
		do_rollback($user_name);
		die "Cannot run task '$script_name': $!";
	}
}

print "Finished.";

sub do_rollback {
	# Stop container
	system("$LXC_BIN stop $user_name");
	$? and die "Cannot do rollback for user '$user_name': $!";

	# Remove container
	system("LVM_REMOVE=1 $LXC_BIN remove $user_name");
	$? and die "Cannot do rollback for user '$user_name': $!";
	return;
}

exit;
