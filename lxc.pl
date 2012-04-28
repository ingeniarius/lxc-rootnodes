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
use File::Copy::Recursive qw(dircopy);
use Tie::File;
use Tie::IxHash;
use Smart::Comments;
$|++;

# Configuration
Readonly my $SERVER_ID        => 1;
Readonly my $SERVER_KEY_FILE  => '/root/.ssh/id_rsa.pub'; 
Readonly my $DEBIAN_VERSION   => 'squeeze';
Readonly my $DEBIAN_ARCH      => 'amd64';
Readonly my $DEBIAN_REPO      => 'http://ftp.fr.debian.org/debian';

Readonly my $LXC_DIR          => '/lxc';
Readonly my $LXC_TEMPLATE_DIR => "$LXC_DIR/template";
Readonly my $LXC_REPO_DIR     => "$LXC_DIR/scripts";
Readonly my $LXC_LOGLEVEL     => 'INFO';
Readonly my $LXC_NETWORK      => "10.$SERVER_ID.0.0";       # Network address without netmask
Readonly my $LXC_DAEMON       => $ENV{DAEMON}     || 1;     # Daemonize lxc-start
Readonly my $LXC_DEFAULT_TYPE => 'user';                    # Default template type

Readonly my $LVM_REMOVE       => $ENV{LVM_REMOVE} || 1;     # WARNING! Users's /home partition will be removed.
Readonly my $LVM_SIZE         => $ENV{LVM_SIZE}   || '6G';  # Volume size
Readonly my $LVM_VG           => 'lxc';                     # Volume group name

Readonly my $USAGE => <<END_OF_USAGE;
\033[1mLXC manager by Rootnode\033[0m
Usage:
    $0 start|stop <name>               start or stop container
    $0 create <name> <id> <type>       create container
    $0 create|remove <name>            remove container
    $0 template <template_name>        create container template
   
    $0 list                            list available container
    $0 ip <id>                         calculate IP address for container
    $0 help                            show usage
   
END_OF_USAGE

Readonly my %IS_READONLY => ( user => 1 );
Readonly my @MOUNT_DIRS => qw(bin dev etc root lib sbin usr var);
my %MOUNT = (
	home => { opts => 'nodev,nosuid' },
	var  => { opts => 'noexec,nodev,nosuid', bind_home_if_readonly => 1 }
);

# Get command name
my $command_name   = shift || 'list';

# Get arguments
my ($container_name, $container_id, $container_type) = @ARGV;
$container_type = $container_type || $LXC_DEFAULT_TYPE;

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
-d $repo_chroot_dir   or die "Cannot find \$repo_chroot_dir ($repo_chroot_dir).\n";
-f $repo_lxcconf_file or die "Cannot find \$repo_lxcconf_file ($repo_lxcconf_file).\n";

-d $LXC_TEMPLATE_DIR  or mkdir $LXC_TEMPLATE_DIR, 0700 or die "Cannot create \$LXC_TEMPLATE_DIR ($LXC_TEMPLATE_DIR).";
 
# Start container
if ($command_name eq 'start') {
	defined $container_name or die "Container name not specified.\n";
	start_container($container_name);
}	
# Stop container
elsif ($command_name eq 'stop') {
	defined $container_name or die "Container name not specified.\n";
	stop_container($container_name);
}
# Create template
elsif ($command_name eq 'template') {
	my $template_name = $container_name;
	defined $template_name or die "Template name not specified.\n";
	create_template($template_name);
}
# Create container
elsif ($command_name eq 'create') {
	defined $container_name or die "Container name not specified.\n";
	defined $container_id   or die "Container ID not specified.\n";
	create_container($container_name, $container_id, $container_type);
}
# Remove container
elsif ($command_name eq 'remove') {
	my $container_name = shift or die "Container name not specified.\n";
	remove_container($container_name);
}
# Show container list
elsif ($command_name eq 'list') {
	list_containers();
}
# Show usage
elsif ($command_name eq 'help') {
	print $USAGE;
}

exit 0;

sub list_containers {
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

	# Create ordered hash table
	tie my %container_list, 'Tie::IxHash';
	
	foreach my $container_type (sort @container_types) {
		my $id_file_global_path = "$LXC_DIR/$container_type/*/id";
		foreach my $container_path (glob $id_file_global_path) {
			print $container_path;
		}
	}
	
	
}

sub create_container { 
	my ($container_name, $container_id, $container_type) = @_;

	### $container_name
	### $container_id
	### $container_type
	
	# Check if container is running
	if (is_container_running($container_name)) {
		die "Container $container_name is running.\n";
	}

	# Umount shares (just in case)
	umount_shares($container_name);
	
	# Create container directory
	-d $container_dir and die "Container $container_name already exists ($container_dir)\n.";
	make_path($container_dir, { mode => 0700 }) or die "Cannot create container_dir $container_dir.";
	
	# Create fstab file
	open my $fstab_fh, '>', $container_fstab_file;
        print $fstab_fh join("\t", 'none', "$container_rootfs_dir/proc", 'proc', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
        print $fstab_fh join("\t", 'none', "$container_rootfs_dir/sys", 'sysfs', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
        close $fstab_fh;

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
	
		# Create logical volume
		my $lv_name = "$container_type-$container_name";
		system("lvcreate -L$LVM_SIZE -n $lv_name $LVM_VG");
		die $! if $?;

		# Create file system
                system("mkfs.ext4 -q $lvm_path");
		die $! if $?;
	} 
	else {
		warn "LVM volume for $container_name exists.\n";
	}

	# Create rootfs content
	mkdir $container_rootfs_dir, 0711 or die "Cannot create $container_rootfs_dir.";

	# Change directory
	chdir $container_rootfs_dir or die "Cannot change directory to $container_rootfs_dir.";

	# Create directories
	mkdir "$container_rootfs_dir/proc"       or die "Cannot create proc directory.";
	mkdir "$container_rootfs_dir/sys"        or die "Cannot create sys directory.";
	mkdir "$container_rootfs_dir/home", 0711 or die "Cannot create home directory.";
	symlink 'lib', 'lib64'                   or die "Cannot create lib64 symlink.";
	
	# Mount /home directory
	mount_shares($container_name, 'home');
	
	# Create tmp directory
	-d 'home/tmp' or mkdir 'home/tmp', 01777 or die "Cannot create home/tmp directory.";
	symlink 'home/tmp', 'tmp'                or die "Cannot create tmp symlink.";

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
	my @ipaddr = get_ipaddr($container_id);
	
	# Get network mask
	my $netmask = pop @ipaddr;

	# Get hardware address (e.g. 00:FF:10:01:12:34)
	my $hwaddr = '00:FF' . join ':', map { sprintf('%02d', $_) } @ipaddr;

	# Get IP address with netmask
	my $ipaddr = join('.', @ipaddr);
	my $ipaddr_netmask = "$ipaddr/$netmask";

	# Get server hostname (e.g. web1.rootnode.net)
	my $server_hostname = `hostname --fqdn`; 
	
	# Get server type (e.g. web) and domain (e.g. rootnode.net)
	my ($server_type, $server_domain) = $server_hostname =~ /^(\w+?)\d+\.([\w.]+)$/;
	die "Cannot get server type or domain." if not defined ($server_type and $server_domain);	

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

sub get_ipaddr {
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
		# Get two digits from container ID (right-hand side)
		my $ipaddr_part = int substr($container_id, -2 * $idx, 2) || 0;

		# Store in ipaddr array  
		$ipaddr[-$idx] = $ipaddr_part;
	}

	# Insert netmask into IP address
	push @ipaddr, $netmask;
	
	return @ipaddr;
}

sub remove_container {
	my ($container_name) = @_;
	
	# Check if container is running
	if (container_is_running($container_name)) {
		die "Cannot remove running container $container_name.\n";
	}

	# Umount shares
	umount_shares($container_name);

	# Check container directory
	-d $container_dir or die "Container directory ($container_dir) not found.\n";

	# Remove container directory
	remove_tree($container_dir) or die "Cannot remove container directory ($container_dir).";

	# Remove LVM logical volume
	if ($LVM_REMOVE) {
		# Show warning
		print "CONTAINER LOGICAL VOLUME ($container_name) WILL BE REMOVED IN 5 SECONDS";
		# Simple dot progress bar
		for (1..5) { 
			print '.' ; 
			sleep 1 
		};

		# Disable logical volume
		my $lv_name = "$LVM_VG/$container_type-$container_name";	
		system("lvchange -an $lv_name");
		die $! if $?;
	
		# Remove logical volume
		system("lvremove $lv_name");
		die $! if $?;
	}

	return;
}

sub create_template {
	my ($template_name) = @_;

	# Create and check paths
	chdir $LXC_TEMPLATE_DIR  or die "Cannot open $LXC_TEMPLATE_DIR directory.";
	-d $template_dir        and die "Template $template_dir directory already exists.";

	mkdir $template_dir, 0700 or die "Cannot create $template_dir directory.";
	chdir $template_dir or die "Cannot open $template_dir directory."; 
	
	# Copy lxc.conf file from repo
	copy( $repo_lxcconf_file, $template_lxcconf_file ) or die "Cannot copy $repo_lxcconf_file.";
	
	# Get server hostname
	my $server_hostname = `hostname`;
	chomp $server_hostname;
	
	# Template hostname
	my $template_hostname = "$template_name.template.$server_hostname";

	# Edit lxc.conf file
	tie my @tie_lxcconf_file, 'Tie::File', $template_lxcconf_file or die "Cannot tie $template_lxcconf_file.";
	for (@tie_lxcconf_file) {
		s/^lxc\.utsname.+/lxc\.utsname = $template_hostname/;
		s/^lxc\.rootfs.+/lxc\.rootfs = $template_rootfs_dir/;
		s/^lxc\.mount.+/lxc\.mount = $template_fstab_file/;
	}
	untie @tie_lxcconf_file or die "Cannot untie $template_lxcconf_file.";

	# Create fstab file
	open my $fstab_fh, '>', 'fstab' or die "Cannot create fstab file.";

	print $fstab_fh join("\t", 'none', "$template_rootfs_dir/proc", 'proc', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
	print $fstab_fh join("\t", 'none', "$template_rootfs_dir//sys", 'sysfs', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
	close $fstab_fh;

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
	
	# Create SSH directory
	if (! -d $template_ssh_dir) {
		make_path($template_ssh_dir, { mode => 0700 }) or die "Cannot create $template_ssh_dir.";
	}
	
	# Copy SSH pub key
	copy( $SERVER_KEY_FILE, "$template_ssh_dir/authorized_keys" ) or die "Cannot copy $SERVER_KEY_FILE";
	
	# Run chroot scripts
	for ( 'chroot', $container_type, $container_name ) {
		# Add .sh suffix to script name
		my $script_name = "$_.sh";	
	
		# Path to script files
		my $repo_script_file     = "$repo_chroot_dir/$script_name";
		my $template_script_file = "$template_rootfs_dir/$script_name"; 

		if (-f $repo_script_file) {
			# Copy chroot script to template rootfs directory
			copy( $repo_script_file, $template_script_file) or die "Cannot copy $repo_script_file.";
			
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

sub chroot_restrictions {
	# 1 is enable, 0 is disable
	my ($flag) = @_; 

	# Read sysctl parameters
	my @sysctl = `sysctl -N -a`;
	chomp @sysctl;

	# Set flag for chroot parameters
        foreach my $param (@sysctl) {
                if($param =~ /^kernel\.grsecurity\.chroot_/) {
                        system("sysctl -w $param=$flag");
                        die $! if $?;
                }
        }

	return;
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

sub mount_shares {
	my ($container_name, $mount_name) = @_;
	$mount_name = $mount_name || '';
	
	### $mount_name

	# Mount /home directory
	my $container_home_dir = "$container_rootfs_dir/home";
	-d $container_home_dir or die "Container home dir $container_home_dir not found.";
		
	my $home_mount_opts = $MOUNT{home}->{opts};
	system("mount -o $home_mount_opts $lvm_path $container_home_dir");
	die $! if $?;

	return 1 if $mount_name eq 'home';

	# Bind mounts
	foreach my $dir_name (@MOUNT_DIRS) {
		my $template_bind_dir  = "$template_rootfs_dir/$dir_name";
		my $container_bind_dir = "$container_rootfs_dir/$dir_name";
		
		# Check directories
		-d $template_bind_dir or die "Template bind dir $template_bind_dir not found.";
		-d $container_bind_dir or die "Container bind dir $container_bind_dir not found.";

		# Check if bind from home directory
		my $bind_home_if_readonly = $MOUNT{$dir_name}->{bind_home_if_readonly} || 0;

		if ($bind_home_if_readonly) {
			my $home_bind_dir = "$container_rootfs_dir/home/$dir_name";
			-d $home_bind_dir or die "Home bind dir $home_bind_dir not found.";
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


sub start_container {
	my ($container_name) = @_;
	
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
	copy( $template_lxcconf_file, $container_conf_file ) or die "Cannot copy $template_lxcconf_file.";

	# Create ordered hash table
	tie my %lxcconf_value_for, 'Tie::IxHash';
	
	# Open container's lxc.conf
	open my $lxcconf_fh, '<', $container_lxcconf_file or die "Cannot open $container_lxcconf_file.";
	
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
	tie my @tie_conf_file, 'Tie::File', $container_conf_file or die "Cannot tie $container_conf_file.";
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

	# Stop LXC
	system("lxc-stop -n $container_name");
	warn $! if $?;

	# Umount shares
	umount_shares($container_name);
	
	return;
}

1;
