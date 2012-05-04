#!/usr/bin/perl
#
# LVM snapshot
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use File::Basename qw(basename);
use Readonly;
use Smart::Comments;

# Configuration
Readonly my $LVM_VG              => 'lxc';       # LVM volume group name
Readonly my $LVM_SNAPSHOT_SUFFIX => 'snapshot';  # Suffix added to LV name 
Readonly my $LVM_SNAPSHOT_SIZE   => '2G';        # Snapshot size
Readonly my $LVM_SNAPSHOT_DIR    => '/snapshot'; # Snapshot mount point

# Terminal
Readonly my $BASENAME => basename($0);
Readonly my $NULL     => '&>/dev/null';

# Usage
Readonly my $USAGE => <<END_OF_USAGE;
LVM snapshot
Usage: 
	$BASENAME create <lv_name> 
	$BASENAME remove <lv_name>
	$BASENAME list <type>
END_OF_USAGE

# Get arguments
my $command_name = shift or die $USAGE;

my $lv_name = shift            or die "LVM logical volume name not specified.\n";
   $lv_name =~ /^[a-z0-9\-]+$/ or die "Incorrect LVM logical volume name.\n";

# Add suffix to LV name
my $snapshot_name = "$lv_name-$LVM_SNAPSHOT_SUFFIX";

# Create snapshot
if ($command_name eq 'create') {
	# Check LV name
	lv_exists($lv_name) or die "Logical volume '$lv_name' not found.\n";
	
	# Remove existing snapshot
	remove_snapshot($snapshot_name);

	# Create snapshot
	create_snapshot($snapshot_name);
	
	# Check if snapshot created
	lv_exists($snapshot_name) or die "Snapshot '$snapshot_name' was not created.\n";
	exit 0;
}

# Remove snapshot
if ($command_name eq 'remove') {
	remove_snapshot($snapshot_name);
	exit 0;
}

# List containers
if ($command_name eq 'list') {
	list_lvs($lv_name);
	exit 0;
}

# Unknown command 
die "Command name '$command_name' not found. See '$BASENAME help'.\n";

sub remove_snapshot {
	my ($snapshot_name) = @_;
	
	if (lv_exists($snapshot_name)) {
		# Umount
		umount_snapshot($snapshot_name);

		# Remove snapshot volume
		system("lvremove -f $LVM_VG/$snapshot_name $NULL");
		$? and die "Cannot remove snapshot '$snapshot_name': $!\n";
	}
	
	return;
}

sub create_snapshot {
	my ($snapshot_name) = @_;

	# Create LVM snapshot
	system("lvcreate -L$LVM_SNAPSHOT_SIZE -s -n $snapshot_name $LVM_VG/$lv_name $NULL");
	$? and die "Cannot create snapshot '$snapshot_name': $!\n";

	# Mount snapshot
	mount_snapshot($snapshot_name);
	$? and die "Cannot mount snapshot '$snapshot_name': $!\n";

	return;
}

sub list_lvs {
	my ($lv_type) = @_;
	my $lv_count;
	
	# Get logical volumes
	my $lvs = `lvs -olv_name --noheading --rows --unbuffered --aligned --separator=,`;
           $lvs =~ s/\s+//g;
        my @lvs =  split /,/, $lvs;

	LV:
	foreach my $lv_name (@lvs) {
		# LV starts with 'type-'
		my $lv_prefix = "$lv_type-";

		# Print LV of specified type
		if ($lv_name =~ /^\Q$lv_prefix\E/) {
			print "$lv_name\n";
			$lv_count++;
		}
	}
	
	# Error if list is empty
	my $is_empty = $lv_count ? 0 : 1;
	die "Logical volumes of type '$lv_type' not found.\n" if $is_empty;

	return;
}

sub mount_snapshot {
	my ($snapshot_name) = @_;
	
	# Snapshot device
	my $snapshot_name_hyphened = $snapshot_name;
	   $snapshot_name_hyphened =~ s/-/--/g;

	my $snapshot_device = "/dev/mapper/$LVM_VG-$snapshot_name_hyphened";

	# Snapshot mount point
	my $snapshot_mount_point = "$LVM_SNAPSHOT_DIR/$snapshot_name";

	# Create mount point
	mkdir $snapshot_mount_point       or die "Cannot create directory '$snapshot_mount_point'";
	chmod 0700, $snapshot_mount_point or die "Cannot chmod directory '$snapshot_mount_point'";

	# Mount snapshot
	system("mount -o ro,noexec $snapshot_device $snapshot_mount_point $NULL");
	$? and die "Cannot mount $snapshot_device: $!\n";

	return;
}

sub umount_snapshot {
	my ($snapshot_name) = @_;
	
	# Snapshot mount point
	my $snapshot_mount_point = "$LVM_SNAPSHOT_DIR/$snapshot_name";

	# Check if snapshot is mounted
	sub is_snapshot_mounted { 
		my ($snapshot_mount_point) = @_;	

		# Get mount information
		my $mount_file = '/proc/mounts';
		open my $mount_fh, '<', $mount_file or die "Cannot open $mount_file";
		my @mounts = <$mount_fh>;
		close $mount_fh;
		
		# Look for mounted device
		for (@mounts) {
			my ($device_name, $mount_point) = split /\s+/; 

			# Trim deleted info (just in case)
			$mount_point =~ s/\\\d+\(deleted\)//;

			# Snapshot is mounted
			if ($mount_point eq $snapshot_mount_point) {
				return 1;
			}
		}

		# Snapshot is not mounted
		return 0;
	}

	TRY:
	for (1..3) {
		# Check if mounted
		my $is_mounted = is_snapshot_mounted($snapshot_mount_point);

		# Umount 
		if ($is_mounted) {
			system("umount $snapshot_mount_point");
			my $umount_error = $?;

			# Try again after 5 second
			if ($umount_error) {
				sleep 5;
				next TRY;
			}
		}

		# Remove mount point
		if (-d $snapshot_mount_point) {
			rmdir $snapshot_mount_point or die "Cannot remove '$snapshot_mount_point' directory";
		}

		# Success
		return;
	}

	# Failure
	die "Cannot umount $snapshot_mount_point: $!\n";
}

sub lv_exists {
	my ($lv_name) = @_;

	system("lvs $LVM_VG/$lv_name $NULL");
	return 0 if $?;
	return 1;
}
