#!/usr/bin/perl
#
# LXC manager
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use Readonly;
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Basename qw(basename);
use File::Copy::Recursive qw(dircopy);
use Sys::Hostname;
use POSIX qw(isdigit);
use Tie::File;
use Tie::IxHash;
use Text::ASCIITable;
use Smart::Comments;
use Data::Dumper;
$|++;

# Configuration
Readonly my $DEBIAN_VERSION    => 'squeeze';
Readonly my $DEBIAN_ARCH       => 'amd64';
Readonly my $DEBIAN_REPO       => 'http://ftp.fr.debian.org/debian';
Readonly my $SYSCTL_GRSEC_FILE => '/etc/sysctl.d/grsec.conf';

Readonly my $SERVER_ID         => get_server_id('br0', '10'); # params: network device and class
Readonly my $SERVER_KEY_FILE   => '/root/.ssh/id_rsa.pub';    # public SSH key for root access

Readonly my $LXC_DIR          => '/lxc';
Readonly my $LXC_TEMPLATE_DIR => "$LXC_DIR/template";
Readonly my $LXC_REPO_DIR     => "$LXC_DIR/scripts";
Readonly my $LXC_NAME_MINLEN  => 2;
Readonly my $LXC_NAME_MAXLEN  => 32;
Readonly my $LXC_ID_MIN       => 2000;
Readonly my $LXC_ID_MAX       => 6500;
Readonly my $LXC_DEFAULT_TYPE => 'user';                    # Default template type
Readonly my $LXC_LOGLEVEL     => 'INFO';
Readonly my $LXC_NETWORK      => "10.$SERVER_ID.0.0";       # Network address without netmask
Readonly my $LXC_DAEMON       => $ENV{DAEMON}     || 1;     # Daemonize lxc-start

Readonly my $LVM_REMOVE       => $ENV{LVM_REMOVE} || 1;     # WARNING! Users's /home partition will be removed.
Readonly my $LVM_SIZE         => $ENV{LVM_SIZE}   || '6G';  # Volume size
Readonly my $LVM_VG           => 'lxc';                     # Volume group name


Readonly my $HOSTNAME => hostname;
Readonly my $BASENAME => basename($0);
Readonly my $NULL1    => '1>/dev/null';
Readonly my $NULL2    => '&>/dev/null';

# Mount options
Readonly my %IS_READONLY => ( user => 1 );
Readonly my @MOUNT_DIRS => qw(bin dev etc root lib sbin usr var);
my %MOUNT = (
	home => { opts => 'nodev,nosuid' },
	var  => { opts => 'noexec,nodev,nosuid', bind_home_if_readonly => 1 }
);

# Terminal colors
Readonly my $RST => "\033[0m";
Readonly my $WHT => "\033[1m";
Readonly my $RED => "\033[1;31m";
Readonly my $GRN => "\033[1;32m";
Readonly my $YEL => "\033[1;33m";
Readonly my $BLU => "\033[1;34m";
Readonly my $MAG => "\033[1;35m";

# ASCII Table
my @empty_array = [ q[], q[], q[ ], q[] ];

Readonly my $TABLE_LAYOUT => [
	@empty_array, @empty_array, @empty_array,
	@empty_array, @empty_array, @empty_array,
];

Readonly my $TABLE_OPTS => {
	allowANSI        => 1,
	undef_as         => '-',
	headingStartChar => ' ',
	headingStopChar  => ' ',
	hide_HeadLine	 => 1,
};

# Usage information
Readonly my $USAGE => <<END_OF_USAGE;
\033[1mLXC manager by Rootnode\033[0m
Basic Usage:
    $BASENAME start|stop <name>                      start or stop container
    $BASENAME create|remove <name> <id> [ <type> ]   create or remove  container
    $BASENAME template <template_name>               create container template
    $BASENAME list                                   list all containers

Helpers:
    $BASENAME ip <id>                                show user IP address
    $BASENAME uid <name>                             show user uid
    $BASENAME id                                     show server id
    $BASENAME ssh <id|name>                          ssh into container
    $BASENAME chroot 1|0                             enable or disable chroot restrictions
    $BASENAME help                                   show usage
   
END_OF_USAGE

# Available commands
my %run_on = (
	start    => 'start_container',
	stop     => 'stop_container',
	create   => 'create_container',
	remove   => 'remove_container',
	template => 'create_template',
	list     => 'show_containers',
	ip       => 'show_ip_address',
	uid      => 'show_user_id',
	id       => 'show_server_id',
	ssh      => 'ssh',
	chroot   => 'chroot_restrictions',
	help     => 'show_usage'
);

# Get command name
my $command_name   = shift || 'list';

# Get arguments
my ($container_name, $container_id, $container_type) = @ARGV;

# Set default container type
$container_type = $container_type || $LXC_DEFAULT_TYPE;
undef $container_type if $command_name eq 'template';

# Container paths
no warnings;
my $container_dir          = "$LXC_DIR/$container_type/$container_name";
my $container_fstab_file   = "$container_dir/fstab"; 
my $container_rootfs_dir   = "$container_dir/rootfs";
my $container_lxcconf_file = "$container_dir/lxc.conf"; 
my $container_log_file     = "$container_dir/log";
my $container_conf_file    = "$container_dir/conf";
my $container_id_file      = "$container_dir/id";
my $container_is_readonly  = $IS_READONLY{$container_type} || 0;

# Template paths
my $template_dir = "$LXC_TEMPLATE_DIR/$container_name";
   $template_dir = "$LXC_TEMPLATE_DIR/$container_type" if $container_is_readonly;
	
my $template_debootstrap_dir = "$LXC_TEMPLATE_DIR/debootstrap-debian_$DEBIAN_VERSION";
my $template_rootfs_dir      = "$template_dir/rootfs";
my $template_ssh_dir         = "$template_dir/rootfs/root/.ssh";
my $template_fstab_file      = "$template_dir/fstab";
my $template_lxcconf_file    = "$template_dir/lxc.conf";

# Repo paths
my $repo_chroot_dir   = "$LXC_REPO_DIR/chroot";
my $repo_lxcconf_file = "$LXC_REPO_DIR/lxc.conf";

# LVM paths
my $lvm_path = "/dev/mapper/$LVM_VG-$container_type--$container_name";
use warnings;

# Create and check paths
-d $LXC_DIR           or die "Cannot find \$LXC_DIR ($LXC_DIR).\n";
-d $LXC_REPO_DIR      or die "Cannot find \$LXC_REPO_DIR ($LXC_REPO_DIR).\n";
-f $SERVER_KEY_FILE   or die "Cannot find \$SERVER_KEY_FILE ($SERVER_KEY_FILE).\n";
-f $SYSCTL_GRSEC_FILE or die "Cannot find \$SYSCTL_GRSEC_FILE ($SYSCTL_GRSEC_FILE).\n";
-d $repo_chroot_dir   or die "Cannot find \$repo_chroot_dir ($repo_chroot_dir).\n";
-f $repo_lxcconf_file or die "Cannot find \$repo_lxcconf_file ($repo_lxcconf_file).\n";

-d $LXC_TEMPLATE_DIR  or mkdir $LXC_TEMPLATE_DIR, 0700 or die "Cannot create \$LXC_TEMPLATE_DIR ($LXC_TEMPLATE_DIR)";
 
# Run command
my $sub_name = $run_on{$command_name} or die "No such command: $command_name. See '$BASENAME help'.\n";
eval "$sub_name(\@ARGV)";
die $@ if $@;

# End program
exit 0;

# Main operations
sub start_container {
	my ($container_name) = @_;
	
	# Check container name
	defined $container_name          or die "Container name not specified.\n";
	
	# Check if container is running
	if (is_container_running($container_name)) {
		die "Container $container_name already running.\n";
	}

	# Check directories and files
	-d $container_dir or die "Container directory ($container_dir) not found.\n";
	-f $template_lxcconf_file or die "Template lxc.conf file ($template_lxcconf_file) not found.\n";
	-f $container_lxcconf_file or die "Container lxc.conf file ($container_lxcconf_file) not found.\n";
	
	# Delete log file
	unlink $container_log_file;
	
	# Copy template's lxc.conf file to conf file
	copy( $template_lxcconf_file, $container_conf_file ) or die "Cannot copy $template_lxcconf_file";

	# Create ordered hash table
	tie my %lxcconf_value_for, 'Tie::IxHash';
	
	# Open container's lxc.conf
	open my $lxcconf_fh, '<', $container_lxcconf_file or die "Cannot open $container_lxcconf_file";
	
	# Read config parameters from lxc.conf file
	while (<$lxcconf_fh>) {
		chomp;
		my ($param, $value) = split /\s*=\s*/;   # get param and value
		next if /^#/;                            # skip comments
		next if not defined ($param and $value); # not an option line
		$lxcconf_value_for{$param} = $value;     # store in hash
	}
	
	# Close container's lxc.conf file
	close $lxcconf_fh;

	# Alter template's config file with container's lxc.conf params
	tie my @tie_conf_file, 'Tie::File', $container_conf_file or die "Cannot tie $container_conf_file";
	for (@tie_conf_file) {
		my ($param, $value) = split /\s*=\s*/;   # get param and value
		next if /^#/;                            # skip comments
		next if not defined ($param and $value); # not an option line
		
		# Substitute value if param defined in container's lxc.conf file
		if (defined $lxcconf_value_for{$param}) {
			s/^$param\s*=.*/$param = $lxcconf_value_for{$param}/;
			delete $lxcconf_value_for{$param};
		}
	}

	# If additional params left in container's lxc.conf file 
	# append to conf file
	if (keys %lxcconf_value_for) {
		push @tie_conf_file, "\n# Other configuration";
		push @tie_conf_file, map { "$_ = $lxcconf_value_for{$_}" } keys %lxcconf_value_for;
	}
	
	# Untie conf file and hash table
	untie %lxcconf_value_for;
	untie @tie_conf_file;	

	# Umount shares (just in case)
	umount_shares($container_name);

	# Mount container directories
	mount_shares($container_name);
	
	# Check /etc configuration
	# XXX

	# Run LXC
	my $lxc_opts = $LXC_DAEMON ? '-d' : '';
	
	system("lxc-start -n $container_name -f $container_conf_file -o $container_log_file -l $LXC_LOGLEVEL $lxc_opts");
	warn $! if $?;
	
	return;
}

sub stop_container {
	my ($container_name) = @_;
	
	# Check container name
	defined $container_name or die "Container name not specified.\n";

	# Stop LXC
	system("lxc-stop -n $container_name");
	warn $! if $?;

	# Umount shares
	umount_shares($container_name);
	
	return;
}

sub create_container { 
	my ($container_name, $container_id, $container_type) = @_;
	
	# Default container type	
	$container_type = $container_type || $LXC_DEFAULT_TYPE;

	# Validate arguments
	validate_container_name($container_name);
	validate_container_id($container_id);
	validate_container_type($container_type);	

	# Check if container is running
	if (is_container_running($container_name)) {
		die "Container $container_name is running.\n";
	}

	# Check if uid is free
	if (container_id_exists($container_id)) {
		die "Container ID $container_id already exists.\n";
	}
	
	# Umount shares (just in case)
	umount_shares($container_name);
	
	# Create container directory
	-d $container_dir and die "Container $container_name already exists ($container_dir).\n";
	make_path($container_dir, { mode => 0700 }) or die "Cannot create container_dir $container_dir";
	# Get LVM volume groups
        my $vgs = `vgs -ovg_name --noheading --rows --unbuffered --aligned --separator=,`;
           $vgs =~ s/\s+//g;
        my %vgs = map { $_ => 1 } split(/,/, $vgs);
	
	# Check volume group
	if (not defined $vgs{$LVM_VG}) {
		die "LVM volume group $LVM_VG not found.\n";
	}

	# Get LVM logical volumes
        my $lvs = `lvs -olv_name --noheading --rows --unbuffered --aligned --separator=,`;
           $lvs =~ s/\s+//g;
        my %lvs = map { $_ => 1 } split(/,/, $lvs);
	
	# Check logical volume
	if (not defined $lvs{$container_name}) {
		# Volume name
		my $lv_name = "$container_type-$container_name";
		
		# Create logical volume
		system("lvcreate -L$LVM_SIZE -n $lv_name $LVM_VG $NULL1");
		die $! if $?;

		# Create file system
                system("mkfs.ext4 -q $lvm_path");
		die $! if $?;
	} 
	else {
		warn "LVM volume for $container_name exists.\n";
	}

	# Create rootfs directory
	mkdir $container_rootfs_dir, 0711 or die "Cannot create $container_rootfs_dir";
	
	# Fstab file
	create_fstab_file($container_fstab_file, $container_rootfs_dir);

	# Change directory
	chdir $container_rootfs_dir or die "Cannot change directory to $container_rootfs_dir";

	# Create directories
	mkdir "$container_rootfs_dir/proc"       or die "Cannot create proc directory";
	mkdir "$container_rootfs_dir/sys"        or die "Cannot create sys directory";
	mkdir "$container_rootfs_dir/home", 0711 or die "Cannot create home directory";
	symlink 'lib', 'lib64'                   or die "Cannot create lib64 symlink";
	
	# Mount /home directory
	mount_shares($container_name, 'home');
	
	# Create tmp directory
	-d 'home/tmp' or mkdir 'home/tmp', 01777 or die "Cannot create home/tmp directory";
	symlink 'home/tmp', 'tmp'                or die "Cannot create tmp symlink";

	# Create mount directories
	foreach my $dir_name (@MOUNT_DIRS) {
                # Check if 'bind from home' directory
		my $bind_home_if_readonly = $MOUNT{$dir_name}->{bind_home_if_readonly} || 0;

		# Copy content from template to home if readonly container
                if ($container_is_readonly and $bind_home_if_readonly) {
			my $template_bind_dir = "$template_rootfs_dir/$dir_name";
			my $home_bind_dir    = "$container_rootfs_dir/home/$dir_name";

			system("cp -pr $template_bind_dir $home_bind_dir");
			die $! if $?;
                }
		
		mkdir $dir_name or die "Cannot create $dir_name directory";
	}
	
	# Umount shares
	umount_shares($container_name);

	# Get IP address
	my @ipaddr = get_ip_address($container_id);
	
	# Get network mask
	my $netmask = pop @ipaddr;

	# Get hardware address (e.g. 00:FF:10:01:12:34)
	my $hwaddr = '00:FF:' . join ':', map { sprintf('%02d', $_) } @ipaddr;

	# Get IP address with netmask
	my $ipaddr = join('.', @ipaddr);
	my $ipaddr_netmask = "$ipaddr/$netmask";

	# Get server type (e.g. web) and domain (e.g. rootnode.net)
	my ($server_type, $server_domain) = $HOSTNAME =~ /^(\w+?)\d+\.([\w.]+)$/;
	die "Cannot get server type or domain" if not defined ($server_type and $server_domain);	

	# Create lxc.conf file
	open my $lxcconf_fh, '>', $container_lxcconf_file;
        print $lxcconf_fh "lxc.utsname = $server_type.$container_name.$server_domain\n"
                        . "lxc.rootfs = $container_rootfs_dir\n"
                        . "lxc.mount = $container_fstab_file\n"
                        . "lxc.network.hwaddr = $hwaddr\n"
                        . "lxc.network.ipv4 = $ipaddr_netmask\n";
        close $lxcconf_fh;

	# Create id file
	open my $id_fh, '>', $container_id_file;
	print $id_fh "$container_id\n";
	close $id_fh;

	return;
}

sub remove_container {
	my ($container_name, $container_id, $container_type) = @_;

	# Validate arguments
	validate_container_name($container_name);
	validate_container_id($container_id);
	validate_container_type($container_type);

	# Check container
	is_container_running($container_name) and die "Cannot remove running container $container_name.\n";
	container_id_exists($container_id)     or die "Container of ID $container_id not found.\n";
	container_name_exists($container_name) or die "Container of name $container_name not found.\n";

	# Umount shares
	umount_shares($container_name);

	# Check container directory
	-d $container_dir or die "Container directory ($container_dir) not found.\n";

	# Remove container directory
	remove_tree($container_dir) or die "Cannot remove container directory ($container_dir)";

	# Remove LVM logical volume
	if ($LVM_REMOVE) {
		my $lv_name = "$LVM_VG/$container_type-$container_name";	

		# Show warning
		print "CONTAINER LOGICAL VOLUME WILL BE REMOVED IN 5 SECONDS ($lvm_path)";

		# Simple dot progress bar
		for (1..5) { 
			print '.' ; 
			sleep 1 
		};
		print "\n";

		# Disable logical volume
		system("lvchange -an $lv_name $NULL1");
		die $! if $?;
	
		# Remove logical volume
		system("lvremove $lv_name $NULL1");
		die $! if $?;
	}

	return;
}

sub create_template {
	my ($template_name) = @_;

	# Check template name	
	defined $template_name            or die "Template name not specified.\n";
	$template_name =~ /^[a-z]{2,16}$/ or die "Unacceptable template name $template_name.\n";

	# Create and check paths
	chdir $LXC_TEMPLATE_DIR  or die "Cannot open $LXC_TEMPLATE_DIR directory";
	-d $template_dir        and die "Template $template_dir directory already exists";

	mkdir $template_dir, 0700 or die "Cannot create $template_dir directory";
	chdir $template_dir or die "Cannot open $template_dir directory"; 
	
	# Copy lxc.conf file from repo
	copy( $repo_lxcconf_file, $template_lxcconf_file ) or die "Cannot copy $repo_lxcconf_file";
	
	# Template hostname
	my $template_hostname = "$template_name.template.$HOSTNAME";

	# Edit lxc.conf file
	tie my @tie_lxcconf_file, 'Tie::File', $template_lxcconf_file or die "Cannot tie $template_lxcconf_file";
	for (@tie_lxcconf_file) {
		s/^lxc\.utsname.+/lxc\.utsname = $template_hostname/;
		s/^lxc\.rootfs.+/lxc\.rootfs = $template_rootfs_dir/;
		s/^lxc\.mount.+/lxc\.mount = $template_fstab_file/;
	}
	untie @tie_lxcconf_file or die "Cannot untie $template_lxcconf_file";

	# Disable chroot restrictions
	chroot_restrictions(0);
	
	# Create debootstrap
	if (! -d $template_debootstrap_dir) {
		system("debootstrap --verbose --arch=$DEBIAN_ARCH $DEBIAN_VERSION $template_debootstrap_dir $DEBIAN_REPO");
                die $! if $?;
	}

	# Copy debootstrap to template
	system("cp -pr $template_debootstrap_dir $template_rootfs_dir");
	die $! if $?;
	
	# Fstab file
	create_fstab_file($template_fstab_file, $template_rootfs_dir);
	
	# Create SSH directory
	if (! -d $template_ssh_dir) {
		make_path($template_ssh_dir, { mode => 0700 }) or die "Cannot create $template_ssh_dir";
	}
	
	# Copy SSH pub key
	copy( $SERVER_KEY_FILE, "$template_ssh_dir/authorized_keys" ) or die "Cannot copy $SERVER_KEY_FILE";
	
	# Run chroot scripts
	for ( 'chroot', $template_name ) {
		# Add .sh suffix to script name
		my $script_name = "$_.sh";	
	
		# Path to script files
		my $repo_script_file     = "$repo_chroot_dir/$script_name";
		my $template_script_file = "$template_rootfs_dir/$script_name"; 

		if (-f $repo_script_file) {
			# Copy chroot script to template rootfs directory
			copy( $repo_script_file, $template_script_file) or die "Cannot copy $repo_script_file";
			
			# Run chroot script 
			system("chroot $template_rootfs_dir /bin/bash /$script_name");
			die $! if $?;
			
			# Remove chroot script from template rootfs directory
			unlink $template_script_file;
		}
	}

	# Enable chroot restrictions
	chroot_restrictions(1);
	
	return;
}

sub mount_shares {
	my ($container_name, $mount_name) = @_;
	$mount_name = '' if not defined $mount_name;
	
	# Mount /home directory
	my $container_home_dir = "$container_rootfs_dir/home";
	-d $container_home_dir or die "Container home dir $container_home_dir not found";
		
	my $home_mount_opts = $MOUNT{home}->{opts};
	system("mount -o $home_mount_opts $lvm_path $container_home_dir");
	die $! if $?;

	return 1 if $mount_name eq 'home';

	# Bind mounts
	foreach my $dir_name (@MOUNT_DIRS) {
		my $template_bind_dir  = "$template_rootfs_dir/$dir_name";
		my $container_bind_dir = "$container_rootfs_dir/$dir_name";
		
		# Check directories
		-d $template_bind_dir or die "Template bind dir $template_bind_dir not found";
		-d $container_bind_dir or die "Container bind dir $container_bind_dir not found";

		# Check if bind from home directory
		my $bind_home_if_readonly = $MOUNT{$dir_name}->{bind_home_if_readonly} || 0;

		if ($bind_home_if_readonly) {
			my $home_bind_dir = "$container_rootfs_dir/home/$dir_name";
			-d $home_bind_dir or die "Home bind dir $home_bind_dir not found";
			$template_bind_dir = $home_bind_dir;
		}
		
		# Get mount options
		my $mount_opts = $MOUNT{$dir_name}->{opts} || 'defaults';

		# Mount directory
		system("mount -o $mount_opts --bind $template_bind_dir $container_bind_dir");
		die $! if $?;

		# Remount read-only if needed
		if ($container_is_readonly and !$bind_home_if_readonly) {
			system("mount -o remount,ro $container_bind_dir");
			die $! if $?;
		}
	}

	return;
}

sub umount_shares {
	my ($container_name) = @_;
	
	# Get mounts information
	open my $mounts_fh, '<', '/proc/mounts';
	my @mount_list = <$mounts_fh>;
	chomp @mount_list;
	close $mounts_fh;
	
	# Check all mounts
	for (@mount_list) {
		# Get mount point
		my ($device_name, $mount_point) = split /\s/; 
		next if not defined ($device_name and $mount_point);
		
		# If mount point belongs to user then umount
		if ($mount_point =~ /^\Q$container_dir\E\//) {
			system("umount $mount_point");
			die $! if $?;
		}
	}

	return;
}

sub create_fstab_file {
	my ($fstab_file, $rootfs_dir) = @_;
	
	# Check paths
	-d $rootfs_dir  or die "Rootfs directory $rootfs_dir not found";
	-f $fstab_file and die "Fstab file $fstab_file already exists";
	
	# Fstab entries
	my $fstab_proc_fs = join "\t", 'none', "$rootfs_dir/proc", 'proc', 'ro,noexec,nosuid,nodev', 0, 0;
	my $fstab_sys_fs  = join "\t", 'none', "$rootfs_dir/sys", 'sysfs', 'ro,noexec,nosuid,nodev', 0, 0;

	# Save fstab file
	open my $fstab_fh, '>', $fstab_file;
        print $fstab_fh $fstab_proc_fs;
        print $fstab_fh $fstab_sys_fs;
        close $fstab_fh;

	return;
}

sub chroot_restrictions {
	my ($flag) = @_; # 1 is enable, 0 is disable
	
	# Check flag value
        defined $flag        or die "Sysctl flag not specified.\n";
        $flag =~ /^(?:1|0)$/ or die "Chroot flag must be 1 or 0.\n";

	# Read sysctl parameters
	my @sysctl = `sysctl -N -a $NULL2`;
	chomp @sysctl;

	# Set flag for chroot parameters
        foreach my $param (@sysctl) {
                if($param =~ /^kernel\.grsecurity\.chroot_/) {
                        system("sysctl -w $param=$flag $NULL2");
                        die $! if $?;
                }
        }

	# Finish if disable mode
	return if $flag == 0;
	
	# Re-run grsec sysctl configuration
	system("sysctl -p $SYSCTL_GRSEC_FILE $NULL2");
	die $! if $?;	
	
	return;
}

# Validators
sub validate_container_id {
	my ($container_id) = @_;
	
	# Check container ID
        defined $container_id  or die "Container ID not specified.\n";
	isdigit($container_id) or die "Container ID $container_id must be a number.\n";

	# Check min and max values
	$container_id < $LXC_ID_MIN and die "Container ID $container_id too low (<$LXC_ID_MIN).\n";
	$container_id > $LXC_ID_MAX and die "Container ID $container_id too high (>$LXC_ID_MAX).\n";

	return;
}

sub validate_container_name {
	my ($container_name) = @_;
	
	# Check container name
        defined $container_name          or die "Container name not specified.\n";
	$container_name =~ /^[a-z0-9]+$/ or die "Wrong container name $container_name.\n"; 
	
	# Check container name length
	length($container_name) < $LXC_NAME_MINLEN and die "Container name $container_name too short.\n";
	length($container_name) > $LXC_NAME_MAXLEN and die "Container name $container_name too long.\n";

	return;
}

sub validate_container_type {
	my ($container_type) = @_;
	
	# Get container types
	my @container_types = get_container_types();
	my %is_container_type = map { $_ => 1 } @container_types;

	# Check container type
	defined $container_type or die "Container type not specified.\n";
	$is_container_type{$container_type} or die "No such container type $container_type.\n"; 
}

# Getters
sub get_container_types {
	# Get subdirectories of lxc
	my @lxc_dirs = `ls -1d $LXC_DIR/*`;
	chomp @lxc_dirs;

	# Store as hash table
	my %lxc_dir = map { $_ => 1 } @lxc_dirs;

	# Delete service directories from hash 
	delete $lxc_dir{$LXC_TEMPLATE_DIR};
	delete $lxc_dir{$LXC_REPO_DIR};

	# Store as array
	my @container_types = keys %lxc_dir;
	
	# Remove path part leaving type name only
	for (@container_types) {
		s/^\Q$LXC_DIR\E\///;
	}

	return sort @container_types;
}

sub get_container_list {	
	# Syntax:
	# by   => 'hash key'
	# type => 'typename',
	my (%param) = @_ ;
	
	# Check mandatory parameters
	defined $param{by} or die "Syntax error. Subroutine 'by' option is mandatory";
	my %container_list;

	# Container types
	my @container_types = get_container_types();

	TYPE:
	foreach my $container_type (@container_types) {
		# Look only for specified type
		if (defined $param{type}) {
			next TYPE unless $container_type eq $param{type};
		}

		# Path to all id files
		my $id_file_glob_path = "$LXC_DIR/$container_type/*/id";
		
		ID:
		foreach my $id_file (glob $id_file_glob_path) {
			# Get container name from path
			my ($container_name) = $id_file =~ /\/(\w+)\/id$/;

			# Check container name
			defined $container_name or die "Cannot get container name from path";
		
			# Open id file
			open my $id_fh, '<', $id_file;
			my $container_id = <$id_fh>;
			chomp $container_id;
			close $id_fh;

			# Validate container ID
			validate_container_id($container_id);

			# Store by id
			if ($param{by} eq 'id') {
				$container_list{$container_id} = $container_name;
			}
			# Store by name
			elsif ($param{by} eq 'name') {
				$container_list{$container_name} = $container_id;
			}
		}
	}
	
	return %container_list;
}

sub get_server_id {
	my ($network_dev, $network_class) = @_;
        my @inet_addr = `ip address show dev $network_dev`;
        for (@inet_addr) {
                # Look for 'inet CLASS.x.x.x/NETMASK' e.g. 10.66.0.1/16 
                if ( my ($server_id) = /inet\s\Q$network_class\E\.(\d+)(?:\.\d+)+\/\d+\s/ ) {
                        return $server_id;
                }
        }
        die "Cannot get \$SERVER_ID (device $network_dev, class $network_class)";
}

sub get_ip_address {
	my ($container_id) = @_;

	# Get network address
	my @ipaddr = split /\./, $LXC_NETWORK;
	
	# How big is our network (count zeros)
	my $zeros_num = 0;
	foreach my $pos (reverse @ipaddr) {
		$pos == 0 ? $zeros_num++ : last;
	}
	
	# No zeros in network address
	$zeros_num < 1 and die "Wrong \$LXC_NETWORK address ($LXC_NETWORK).\n";

	# We allocate only 2 digits per IPv4 position.
	length($container_id) > $zeros_num * 2 and die "Container ID $container_id too big for \$LXC_NETWORK address ($LXC_NETWORK).\n";

	# Get network mask
	my $netmask = 32 - 8 * $zeros_num;

	# Calculate IP address
	for my $idx (1..$zeros_num) {
		# Get id length
		my $id_length = length $container_id;

		# Insert 0 if ID is too short for next IP field
		if ($idx > $id_length) {
			$ipaddr[-$idx] = 0;	
			next;
		}

		# Get two digits from right-hand side of container ID
		my $ipaddr_part = substr($container_id, -2 * $idx, 2) || 0;
		
		# Store in ipaddr array  
		$ipaddr[-$idx] = int $ipaddr_part;
	}

	# Insert netmask into IP address
	push @ipaddr, $netmask;
	
	return @ipaddr;
}

# Boolean checkers
sub container_id_exists {
	my ($container_id) = @_;
	my %container_name_for = get_container_list(by => 'id');
	return 1 if defined $container_name_for{$container_id};
	return 0;
}

sub container_name_exists {
	my ($container_name) = @_;
	my %container_id_for = get_container_list(by => 'name');
	return 1 if defined $container_id_for{$container_name};
	return 0;	
}

sub is_container_running {
	my ($container_name) = @_;

	# Get running containers
	my @container_list = `lxc-ls -1`;
	chomp @container_list;

	# Store as hash table
	my %is_running = map { $_ => 1 } @container_list;
	
	return 1 if $is_running{$container_name};
	return 0;
}

# Helpers
sub show_containers {
	# Container types
	my @container_types = get_container_types();

	TYPE:
	foreach my $container_type (@container_types) {
		# Get container list by id
		my %container_name_for = get_container_list(by => 'id', type => $container_type);
	
		# Initialize table
		my $ascii_table = Text::ASCIITable->new($TABLE_OPTS);

		# Set table columns
		$ascii_table->setCols( ["${WHT}uid", 'user', "status${RST}" ]);

		# Prepare table data
		my @table_rows;

		ID:
		foreach my $container_id (keys %container_name_for) {
			# Container name
			my $container_name = $container_name_for{$container_id};

			# Get container status
			my $container_status = is_container_running($container_name);
			   $container_status = $container_status ? "${GRN}running${RST}" : "${RED}stopped${RST}";
			
			# Add row to table
			push @table_rows, [ $container_id, $container_name, $container_status ];
		}

		# Skip empty table
		my $table_size = scalar @table_rows;
		if (!$table_size) {
			next TYPE;
		}

		# Add rows to table
		foreach my $row (@table_rows) {
			$ascii_table->addRow( @$row );
		}

		# Print table
		my $uc_container_type = ucfirst($container_type);
		print "${BLU}$uc_container_type${RST} ($table_size in total)\n";
		print $ascii_table->draw(@$TABLE_LAYOUT);
	}

	return;
}

sub show_ip_address {
	my ($container_id) = @_;
	
	# Check container ID
	defined $container_id  or die "Container ID not specified.\n";
	isdigit($container_id) or die "Container ID $container_id must be a number.\n";
	
	# Get IP address
	my @ipaddr = get_ip_address($container_id); 
	
	# Remove netmask from IP address
	pop @ipaddr;                         
	
	# Store as string
	my $ipaddr = join '.', @ipaddr; 
	
	# Print result
	print "$ipaddr\n";
	return;
}

sub show_server_id {
	print "$SERVER_ID\n";
	return;
}

sub show_usage {
	print $USAGE;
}
