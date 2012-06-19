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
use File::Basename qw(basename);
use Data::Validate::IP qw(is_ipv4);
use Sys::Hostname;
use POSIX qw(isdigit);
use Tie::File;
use Tie::IxHash;
use Text::ASCIITable;
use Smart::Comments;
$|++;

# System configuration
Readonly my $HOSTNAME          => hostname;                           # Server host name
Readonly my $DEBIAN_VERSION    => 'squeeze';                          # Debian version
Readonly my $DEBIAN_ARCH       => 'amd64';                            # System architecture
Readonly my $DEBIAN_REPO       => 'http://ftp.fr.debian.org/debian';  # Debian repository
Readonly my $NETWORK_IFACE     => 'br0';                              # Network interface
Readonly my $SYSCTL_GRSEC_FILE => '/etc/sysctl.d/grsec.conf';         # Explicit sysctl flags for Grsecurity


# Server configuration
Readonly my $SERVER_ID       => get_server_info('id');      # Server id
Readonly my $SERVER_TYPE     => get_server_info('type');    # Server type, e.g. web
Readonly my $SERVER_NO       => get_server_info('no');      # Server number, e.g. '2' for web2
Readonly my $SERVER_DOMAIN   => get_server_info('domain');  # Server domain 
Readonly my $SERVER_CPUS     => get_server_info('cpus');    # Number of server processors
Readonly my $SERVER_KEY_FILE => '/root/.ssh/id_rsa.pub';    # Public SSH key for root access

# LXC configuration
Readonly my $LXC_DIR          => '/lxc';                       # Main LXC directory
Readonly my $LXC_TEMPLATE_DIR => "$LXC_DIR/template";          # Template directory
Readonly my $LXC_REPO_DIR     => "$LXC_DIR/repo/lxc-manager";  # Repository path to this script and other tools
Readonly my $LXC_NAME_MINLEN  => 2;                            # Minimum container name length
Readonly my $LXC_NAME_MAXLEN  => 32;                           # Maximum container name length
Readonly my $LXC_UID_MIN      => 2000;                         # Minimum UID
Readonly my $LXC_UID_MAX      => 6500;                         # Maximum UID
Readonly my $LXC_DEFAULT_TYPE => 'user';                       # Default container type
Readonly my $LXC_LOGLEVEL     => 'INFO';                       # lxc-start log level
Readonly my $LXC_NETWORK      => "10.$SERVER_ID.0.0";          # Network address w/o netmask
Readonly my $LXC_DAEMON       => $ENV{DAEMON} || 1;            # Daemonize lxc-start process

# LVM configuration
Readonly my $LVM_REMOVE => $ENV{LVM_REMOVE} || 1;     # WARNING! Users's /home partition will be removed.
Readonly my $LVM_SIZE   => $ENV{LVM_SIZE}   || '6G';  # Volume size
Readonly my $LVM_VG     => 'lxc';                     # Volume group name

# Terminal configuration
Readonly my $BASENAME => basename($0);   # Script basename
Readonly my $NULL1    => '1>/dev/null';  # Do not display stdout
Readonly my $NULL2    => '2>/dev/null';  # Do not display stderr
Readonly my $RST      => "\033[0m";      # Reset color
Readonly my $WHT      => "\033[1m";      # White
Readonly my $RED      => "\033[1;31m";   # Red
Readonly my $GRN      => "\033[1;32m";   # Green
Readonly my $YEL      => "\033[1;33m";   # Yellow
Readonly my $BLU      => "\033[1;34m";   # Blue
Readonly my $MAG      => "\033[1;35m";   # Magenta

# Mount options
Readonly my %IS_READONLY => ( user => 1, backup => 1, dev=> 1 );
Readonly my @MOUNT_DIRS => qw(bin dev etc root lib sbin usr var);
my %MOUNT = (
	home => { opts => 'nobarrier,noatime,nodev,nosuid' },
	var  => { opts => 'noexec,nodev,nosuid', bind_home_if_readonly => 1 },
);
#	root => { opts => 'noexec,nodev,nosuid', bind_home_if_readonly => 1 }

# Table layout
my @empty_array = [ q[], q[], q[ ], q[] ];
Readonly my $TABLE_LAYOUT => [
	@empty_array, @empty_array, @empty_array,
	@empty_array, @empty_array, @empty_array,
];

# Table options
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
    $BASENAME start|stop <name>                 start or stop container
    $BASENAME create|remove <name> <id> <type>  create or remove  container
    $BASENAME template <template_name>          create container template
    $BASENAME list                              list all containers

Helpers:
    $BASENAME ip <id>                                show user IP address
    $BASENAME uid <name>                             show user uid
    $BASENAME id                                     show server id
    $BASENAME type                                   show server type
    $BASENAME ssh <id|name>                          ssh into container
    $BASENAME chroot 1|0                             enable or disable chroot restrictions
    $BASENAME help                                   show usage
   
END_OF_USAGE

# Get command name
my $command_name   = shift || 'list';

# Syntax
if (not defined $main::{"command_$command_name"}) {
	die "Command '$command_name' not found. See '$BASENAME help'.\n";
}

# Get arguments
my ($container_name, $container_id, $container_type) = @ARGV;
$container_name = '' if not defined $container_name;
$container_id   = '' if not defined $container_id;

# Get container type if container is already created
if (not defined $container_type) {
	$container_type = get_container_type($container_name);
}

# Container paths
my $container_dir          = "$LXC_DIR/$container_type/$container_name";
my $container_fstab_file   = "$container_dir/fstab"; 
my $container_rootfs_dir   = "$container_dir/rootfs";
my $container_lxcconf_file = "$container_dir/lxc.conf"; 
my $container_log_file     = "$container_dir/log";
my $container_conf_file    = "$container_dir/conf";
my $container_id_file      = "$container_dir/id";
my $container_etc_dir      = "$container_rootfs_dir/home/etc";
my $container_is_readonly  = $IS_READONLY{$container_type} || 0;

# Template name
my $template_name = $container_name; 
   $template_name = $container_type if $container_is_readonly; 
   $template_name = $container_name if $command_name eq 'template';

# Template paths
my $template_dir             = "$LXC_TEMPLATE_DIR/$template_name";
my $template_debootstrap_dir = "$LXC_TEMPLATE_DIR/debootstrap-debian_$DEBIAN_VERSION";
my $template_rootfs_dir      = "$template_dir/rootfs";
my $template_ssh_dir         = "$template_dir/rootfs/root/.ssh";
my $template_fstab_file      = "$template_dir/fstab";
my $template_lxcconf_file    = "$template_dir/lxc.conf";
my $template_etc_dir         = "$template_rootfs_dir/home/etc";

# Repo paths
my $repo_chroot_dir   = "$LXC_REPO_DIR/chroot-scripts";
my $repo_lxcconf_file = "$LXC_REPO_DIR/lxc.conf";

# LVM paths
my $lvm_path   = "/dev/mapper/$LVM_VG-$container_type--$container_name";
my $lvm_lvname = "$container_type-$container_name"; 

# Check paths
-d $LXC_DIR           or die "Cannot find \$LXC_DIR ($LXC_DIR).\n";
-d $LXC_REPO_DIR      or die "Cannot find \$LXC_REPO_DIR ($LXC_REPO_DIR).\n";
-f $SERVER_KEY_FILE   or die "Cannot find \$SERVER_KEY_FILE ($SERVER_KEY_FILE).\n";
-f $SYSCTL_GRSEC_FILE or die "Cannot find \$SYSCTL_GRSEC_FILE ($SYSCTL_GRSEC_FILE).\n";
-d $repo_chroot_dir   or die "Cannot find \$repo_chroot_dir ($repo_chroot_dir).\n";
-f $repo_lxcconf_file or die "Cannot find \$repo_lxcconf_file ($repo_lxcconf_file).\n";

# Create paths
-d $LXC_TEMPLATE_DIR  or mkdir $LXC_TEMPLATE_DIR, 0700 or die "Cannot create \$LXC_TEMPLATE_DIR ($LXC_TEMPLATE_DIR)";

# Other checks
is_ipv4($LXC_NETWORK) or die "Network address \$LXC_NETWORK ($LXC_NETWORK) is not a correct IPv4 address\n"; 
$HOSTNAME =~ /\./     or die "Short \$HOSTNAME ($HOSTNAME) not supported.\n";

# Run command
my @container_params = ($container_name, $container_id, $container_type);
eval "command_$command_name(\@container_params)";
die $@ if $@;

# End program
exit 0;

# Available commands
sub command_start {
	my ($container_name, undef, $container_type) = @_;

	# Validate arguments
	validate_container_name($container_name);

	# Check container
	is_container_running($container_name) and die "Container '$container_name' already running.\n";

	# Check directories and files
	-d $container_dir          or die "Container directory ($container_dir) not found.\n";
	-f $template_lxcconf_file  or die "Template lxc.conf file ($template_lxcconf_file) not found.\n";
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
	
	# Update /etc configuration
	update_etc_files($container_name) if $container_is_readonly;

	# Run LXC
	my $lxc_opts = $LXC_DAEMON ? '-d' : '';
	
	system("lxc-start -n $container_name -f $container_conf_file -o $container_log_file -l $LXC_LOGLEVEL $lxc_opts");
	warn $! if $?;
	
	return;
}

sub command_stop {
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

sub command_create { 
	my ($container_name, $container_id, $container_type) = @_;
	
	# Validate arguments
	validate_container_name($container_name);
	validate_container_id($container_id);
	validate_container_type($container_type);	
	validate_template_name($template_name);

        # Check UID
        if ($container_is_readonly) {
                $container_id < $LXC_UID_MIN and die "Container ID '$container_id' too low (<$LXC_UID_MIN).\n";
                $container_id > $LXC_UID_MAX and die "Container ID '$container_id' too high (>$LXC_UID_MAX).\n";
        }

	# Check container
	is_container_running($container_name) and die "Container '$container_name' is running.\n";
	container_id_exists($container_id)    and die "Container ID '$container_id' already exists.\n";

	# Umount shares (just in case)
	umount_shares($container_name);
	
	# Create container directory
	-d $container_dir                          and die "Container '$container_name' already exists ($container_dir).\n";
	make_path($container_dir, { mode => 0700 }) or die "Cannot create container directory '$container_dir'";

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
	if (!-d 'home/tmp') {
		mkdir 'home/tmp'          or die "Cannot create home/tmp directory";
		chmod 01777, 'home/tmp'   or die "Cannot chmod home/tmp directory";
		symlink 'home/tmp', 'tmp' or die "Cannot create tmp symlink";
	}

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

	# Copy non-shared etc configuration
	if (-d $template_etc_dir and $container_is_readonly) {
		system("cp -pr $template_etc_dir $container_etc_dir");
		die $! if $?;
	}

	# Umount shares
	umount_shares($container_name);

	# Get IP address
	my @ipaddr = get_container_ip($container_id);
	
	# Get network mask
	my $netmask = pop @ipaddr;

	# Get hardware address (e.g. 00:FF:10:01:12:34)
	my $hwaddr = '00:FF:' . join ':', map { sprintf('%02d', $_) } @ipaddr;

	# Get IP address with netmask
	my $ipaddr = join('.', @ipaddr);
	my $ipaddr_netmask = "$ipaddr/$netmask";

	# Create lxc.conf file
	open my $lxcconf_fh, '>', $container_lxcconf_file;
        print $lxcconf_fh "lxc.utsname = $SERVER_TYPE.$container_name.$SERVER_DOMAIN\n"
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

sub command_remove {
	my ($container_name) = @_;

	# Validate arguments
	validate_container_name($container_name);

	# Check container
	is_container_running($container_name) and die "Cannot remove running container $container_name.\n";
	container_name_exists($container_name) or die "Container of name $container_name not found.\n";
	#container_id_exists($container_id)     or die "Container of ID $container_id not found.\n";

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

sub command_template {
	my ($template_name) = @_;

	# Validate arguments
	validate_template_name($template_name);

	# Check paths
	chdir $LXC_TEMPLATE_DIR   or die "Cannot open $LXC_TEMPLATE_DIR directory";
	-d $template_dir         and die "Template $template_dir directory already exists";

	# Create directories
	mkdir $template_dir, 0700 or die "Cannot create $template_dir directory";
	chdir $template_dir       or die "Cannot open $template_dir directory"; 
	
	# Copy lxc.conf file from repo
	copy( $repo_lxcconf_file, $template_lxcconf_file ) or die "Cannot copy $repo_lxcconf_file";
	
	# Template hostname
	my $template_hostname = "$template_name.template.$HOSTNAME";
	
	# Prepare cpuset (e.g. 0-5 for 6 cpus)
	my $cpuset_string = '0-' . ($SERVER_CPUS-1);

	# Edit lxc.conf file
	tie my @tie_lxcconf_file, 'Tie::File', $template_lxcconf_file or die "Cannot tie $template_lxcconf_file";
	for (@tie_lxcconf_file) {
		s/^lxc\.utsname.+/lxc\.utsname = $template_hostname/;
		s/^lxc\.rootfs.+/lxc\.rootfs = $template_rootfs_dir/;
		s/^lxc\.mount.+/lxc\.mount = $template_fstab_file/;
		s/^lxc\.cgroup\.cpuset\.cpus.+/lxc\.cgroup\.cpuset\.cpus = $cpuset_string/;
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

sub command_list {
	# Container types
	my @container_type_list = get_container_type_list();

	TYPE:
	foreach my $container_type (@container_type_list) {
		# Get container list by id
		my %container_name_for = get_container_name_list('id', $container_type);
	
		# Initialize table
		my $ascii_table = Text::ASCIITable->new($TABLE_OPTS);

		# Set table columns
		$ascii_table->setCols( ["${WHT}uid", 'username', 'address', "status${RST}" ]);

		# Prepare table data
		my @table_rows;

		ID:
		foreach my $container_id (sort { $a <=> $b } keys %container_name_for) {
			# Container name
			my $container_name = $container_name_for{$container_id};

			# Get container status
			my $container_status = is_container_running($container_name);
			   $container_status = $container_status ? "${GRN}running${RST}" : "${RED}stopped${RST}";

			# IP address
			my $container_ipaddr = get_container_ip($container_id);
			
			# Add row to table
			push @table_rows, [ $container_id, $container_name, $container_ipaddr, $container_status ];
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

sub command_ip {
	my ($container_id) = @_;
	
	# Validate arguments
	validate_container_id($container_id);
	
	# Get IP address
	my $ipaddr = get_container_ip($container_id); 
	
	# Print result
	print "$ipaddr\n";
	return;
}

sub command_id {
	print "$SERVER_ID\n";
	return;
}

sub command_help {
	print $USAGE;
}

sub command_chroot {
	my ($chroot_flag) = @_;
	chroot_restrictions($chroot_flag);
	return;
}

sub command_ssh {
	my ($container_name) = @_;
	
	# Validate arguments
	validate_container_name($container_name);
	
	# Get container id
	my $container_id = get_container_id($container_name);
	defined $container_id or die "Container '$container_name' not found.\n";
	
	# Get container IP address
	my $ipaddr = get_container_ip($container_id);
	
	# Skip container name in arguments
	shift @ARGV;

	# Show container information
	warn "Username:   $container_name\n";
	warn "UID:        $container_id\n";
	warn "Address:    $ipaddr\n";	
	warn "Running ssh...\n";

	# Run SSH
	system ("ssh -oStrictHostKeyChecking=no root\@$ipaddr @ARGV");
	return;
}

sub command_uid {
	my ($container_name) = @_;
	
	# Validate arguments
	validate_container_name($container_name);
	
	# Get container id	
	my $container_id = get_container_id($container_name);
	
	# Print results
	defined $container_id or die "Container '$container_name' not found.\n";
	print "$container_id\n";	
	return;
}

sub command_type {
	print "$SERVER_TYPE\n";
	return;
}

sub command_no {
	print "$SERVER_NO\n";
	return;
}

sub update_etc_files {
	my ($container_name) = @_;
	
	# Etc paths
	my $container_etc_dir = "$container_rootfs_dir/home/etc";
	my $template_etc_dir  = "$template_rootfs_dir/home/etc";
		
	# Get container files
	my @container_files = glob("$container_etc_dir/*");
	s/^\Q$container_etc_dir\E\/// for @container_files; # trim full path from file name
	
	# Store as hash table
	my %in_container = map { $_ => 1 } @container_files;
	
	# Get template files
	my @template_files = glob("$template_etc_dir/*");
	s/^\Q$template_etc_dir\E\/// for @template_files; # trim full path from file name
	
	# Compare files and copy
	foreach my $file_name (@template_files) {
		if (!$in_container{$file_name}) {
			my $template_file_path  = "$template_etc_dir/$file_name";
			my $container_file_path = "$container_etc_dir/$file_name"; 

			# Directory
			if (-d $template_file_path) {
				### Copying directory: $template_file_path
				dircopy( $template_file_path, $container_file_path ) or die "Cannot copy file $template_file_path: $!";
			}
			# File
			else {
				### Copying file: $template_file_path
				copy( $template_file_path, $container_file_path ) or die "Cannot copy file $template_file_path: $!";
			}
		}	
	}
	
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

		if ($container_is_readonly and $bind_home_if_readonly) {
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
			$mount_point =~ s/\\040\(deleted\)//; # trim deleted info 
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
        print $fstab_fh "$fstab_proc_fs\n";
        print $fstab_fh "$fstab_sys_fs\n";
        close $fstab_fh;

	return;
}

sub chroot_restrictions {
	my ($chroot_flag) = @_;
	
	# Check flag value (1 is enable, 0 is disable)
        defined $chroot_flag        or die "Sysctl flag not specified.\n";
        $chroot_flag =~ /^(?:1|0)$/ or die "Chroot flag must be 1 or 0.\n";

	# Read sysctl parameters
	my @sysctl = `sysctl -N -a $NULL2`;
	chomp @sysctl;

	# Set flag for chroot parameters
        foreach my $param (@sysctl) {
                if($param =~ /^kernel\.grsecurity\.chroot_/) {
                        system("sysctl -w $param=$chroot_flag $NULL1 $NULL2");
                        die $! if $?;
                }
        }

	# Finish if disable mode
	return if $chroot_flag == 0;
	
	# Re-run grsec sysctl configuration
	system("sysctl -p $SYSCTL_GRSEC_FILE $NULL1 $NULL2");
	die $! if $?;	
	
	return;
}

# Validators
sub validate_container_id {
	my ($container_id) = @_;

	# Check container ID
        defined $container_id  or die "Container ID not specified.\n";
	$container_id eq ''   and die "Container ID is empty.\n";
	isdigit($container_id) or die "Container ID '$container_id' must be a number.\n";

	return;
}

sub validate_container_name {
	my ($container_name) = @_;
	
	# Check container name
        defined $container_name          or die "Container name not specified.\n";
	$container_name eq ''           and die "Container name is empty.\n";
	$container_name =~ /^[a-z0-9]+$/ or die "Wrong container name '$container_name'.\n"; 
	
	# Check container name length
	length($container_name) < $LXC_NAME_MINLEN and die "Container name '$container_name' too short.\n";
	length($container_name) > $LXC_NAME_MAXLEN and die "Container name '$container_name' too long.\n";

	return;
}

sub validate_container_type {
	my ($container_type) = @_;
	
	# Get container types
	my @container_type_list = get_container_type_list();
	my %is_container_type = map { $_ => 1 } @container_type_list;

	# Check container type
	defined $container_type             or die "Container type not specified.\n";
	$container_type eq ''              and die "Container type is empty.\n";
	$container_type =~ /^[a-z0-9]+$/    or die "Wrong container type '$container_type'.\n";
	$is_container_type{$container_type} or die "No such container type '$container_type'.\n"; 

	return;
}

sub validate_template_name {
	validate_container_name(@_);
	return;
}

# Getters
sub get_container_type_list {
	# Get subdirectories of lxc
	my @lxc_dirs = `ls -1d $LXC_DIR/*`;
	chomp @lxc_dirs;

	# Store as hash table
	my %lxc_dir = map { $_ => 1 } @lxc_dirs;

	# Delete service directories from hash 
	delete $lxc_dir{$LXC_TEMPLATE_DIR};
	delete $lxc_dir{$LXC_REPO_DIR};

	# Store as array
	my @container_type_list = keys %lxc_dir;
	
	# Remove path part leaving type name only
	for (@container_type_list) {
		s/^\Q$LXC_DIR\E\///;
	}

	return sort @container_type_list;
}

sub get_container_id {
	my ($container_name) = @_;
	
	my %container_list_by_name = get_container_name_list('name');
	my $container_id = $container_list_by_name{$container_name} ;

	return $container_id;
}

sub get_container_type {
	my ($container_name) = @_;
	
	# Get container list
	my %container_list_by_type = get_container_name_list('type');
				
	TYPE:
	foreach my $container_type (keys %container_list_by_type) {
		my %container_list_by_name = %{ $container_list_by_type{$container_type} };
		if (defined $container_list_by_name{$container_name}) {
			return $container_type;
		}
	}
	
	return $LXC_DEFAULT_TYPE;
}

sub get_container_name_list {	
	my ($sort_by, @requested_types) = @_;
	
	# Default values
	$sort_by = $sort_by || 'id';

	# Boolean helpers
	my %is_requested_type      = map { $_ => 1 } @requested_types;
	my $is_type_filter_enabled = scalar @requested_types;

	# Container types
	my @container_type_list = get_container_type_list();

	my %container_list;

	TYPE:
	foreach my $container_type (@container_type_list) {
		# Skip not requested types
		if ($is_type_filter_enabled) {
			next TYPE unless $is_requested_type{$container_type};
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

			# Container list by id
			if ($sort_by eq 'id') {
				$container_list{$container_id} = $container_name;
			}
			# Container list by name
			elsif ($sort_by eq 'name') {
				$container_list{$container_name} = $container_id;
			}
			# Container list by type
			elsif ($sort_by eq 'type') {
				$container_list{$container_type}->{$container_name} = $container_id;
			}
		}
	}
	
	return %container_list;
}

sub get_server_info {
	my ($info_type) = @_; 

	# Server ID
	if ($info_type eq 'id') {
		my @inet_addr = `ip address show dev $NETWORK_IFACE`;
		for (@inet_addr) {
			# Look for 'inet CLASS.x.x.x/NETMASK' e.g. 10.66.0.1/16 
			if ( my ($server_id) = /inet\s(?:10|192\.168\|172\.16)\.(\d+)(?:\.\d+)+\/\d+\s/ ) {
				return $server_id;
			}
		}
		die "Cannot get \$SERVER_ID";
	}

	# Get server type (e.g. web) and server domain (e.g. rootnode.net)
	my ($server_type, $server_no, $server_domain) = $HOSTNAME =~ /^(\w+?)(\d+)\.([\w.]+)$/;
	defined ($server_type and $server_domain) or die "Cannot get server type or domain from \$HOSTNAME ($HOSTNAME)";

	# Server type
	if ($info_type eq 'type') {
		return $server_type;
	}

	# Server no
	if ($info_type eq 'no') {
		return $server_no;
	}

	# Server domain
	if ($info_type eq 'domain') {
		return $server_domain;
	}

	# Server cpus
	if ($info_type eq 'cpus') {
		my $cpu_number = `grep -c processor /proc/cpuinfo`;
		chomp $cpu_number;
		return $cpu_number;
	}
}

sub get_container_ip {
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

	# String version of IP address
	my $ipaddr = join('.', @ipaddr);
	 
	# Insert netmask into IP address
	push @ipaddr, $netmask;
	
	return wantarray ? @ipaddr : $ipaddr;
}

# Boolean checkers
sub container_id_exists {
	my ($container_id) = @_;
	my %container_list_by_id = get_container_name_list('id');
	return 1 if defined $container_list_by_id{$container_id};
	return 0;
}

sub container_name_exists {
	my ($container_name) = @_;
	my %container_list_by_name = get_container_name_list('name');
	return 1 if defined $container_list_by_name{$container_name};
	return 0;	
}

sub is_container_running {
	my ($container_name) = @_;

	# Get running containers
	my @container_list = `lxc-ls -1`;
	chomp @container_list;

	# Store as hash table
	my %is_container_running = map { $_ => 1 } @container_list;
	
	return 1 if $is_container_running{$container_name};
	return 0;
}
