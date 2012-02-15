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
use File::Path     qw(make_path remove_tree);
use File::Copy     qw(copy);
use File::Basename qw(basename);
use Tie::File;
use Tie::IxHash;
use Data::Dumper;
$|++;

# configuration
my $dir = {
	user     => '/lxc/users',
	system   => '/lxc/system',
	template => '/lxc/template',
	bin      => '/lxc/scripts'
};

my $lvm = {
	vg     => 'lxc',        # volume name
	size   => '10G',        # volume size
	remove => 1             # WARNING! User's /home partition will be removed.
};

my $lxc = {
	network => '10.10.0.0', # w/o netmask 
	system  => 'rw',        # type of system container
	user    => 'ro',        # type of user   container
	log     => 'INFO'       # log priority
};

my $template = {
	debian  => 'squeeze',
	repo    => 'http://ftp.fr.debian.org/debian',
	lxc     => 'lxc.conf'
};

# main
my($command, $container, $id, $type);
if(@ARGV >= 2) {
	($command, $container, $id, $type) = @ARGV;
	
	# check paths
	foreach my $key (keys %$dir) {
		unless(-d $dir->{$key}) {
			die ucfirst($key)." directory (".$dir->{$key}.") does NOT exist.\n" 
			  . "Change configuration or create directories first."
		}
	}
	
	# container type 
	for('user','system') {
		if(-d $dir->{$_} . '/' . $container) {
			$type = $_;
			last;
		}
	}
	$type = 'user' unless defined $type;
	$lxc->{type} = $type || 'user';

	# directories and files
	$dir->{container}        = join('/', $dir->{$lxc->{type}},       $container);
	$dir->{fstab}            = join('/', $dir->{container},   'fstab');
	$dir->{rootfs}           = join('/', $dir->{container},   'rootfs');

	$template->{container}   = join('/', $dir->{template},    $container);
	$template->{debootstrap} = join('/', $dir->{template},    'debootstrap-debian_'.$template->{debian});
	$template->{rootfs}      = join('/', $template->{container}, 'rootfs');
	$template->{fstab}       = join('/', $template->{container}, 'fstab');
	$template->{tmpl_chroot} = join('/', $dir->{bin}, 'chroot');
	$template->{tmpl_lxc}    = join('/', $dir->{bin}, $template->{lxc}); 

	if(-d $template->{container}) {
		$dir->{tmpl} = $template->{container};
	} else {
		$dir->{tmpl} = join('/', $dir->{template}, $lxc->{type});	
	}

	$dir->{tmpl_rootfs}  = join('/', $dir->{tmpl}, 'rootfs');
	$dir->{tmpl_conf}    = join('/', $dir->{tmpl}, 'lxc.conf');

	__PACKAGE__->$command($container, $id);
} else {
	&help;
}

sub create {
	my($self, $container, $id) = @_;
	my $type = $lxc->{type};

	if(not defined $id) {
		die "ID not defined. See help.\n";
	} else {
		print "Creating container in " . $dir->{$type} . "...\n";
		print "Using container template from ".$dir->{tmpl}."\n";
	}
	
	&is_running($container);

	# container directory
	if(-d $dir->{container}) {
		die "Container already exists (".$dir->{container}.").\nRemove container first.\n";
	} else {
		make_path($dir->{container}) or die;
	}

	chdir($dir->{container});
	
	# fstab
	open(FSTAB, '>', $dir->{fstab});
	print FSTAB join("\t", 'none', $dir->{rootfs}.'/proc', 'proc', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
	print FSTAB join("\t", 'none', $dir->{rootfs}.'/sys', 'sysfs', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
	close FSTAB;

	# lvm
	my $vgs = `vgs -ovg_name --noheading --rows --unbuffered --aligned --separator=,`;
	   $vgs =~ s/\s+//g;
	my %vgs = map { $_ => 1 } split(/,/, $vgs);

	if(not defined $vgs{$lvm->{vg}}) {
		die "VG (".$lvm->{vg}.") does NOT exist. Check configuration and LVM.";
	}
	
	my $lvs = `lvs -olv_name --noheading --rows --unbuffered --aligned --separator=,`;
	   $lvs =~ s/\s+//g;
	my %lvs = map { $_ => 1 } split(/,/, $lvs);

	&umount($container);

	if(not defined $lvs{$container}) {
		system("lvcreate -L".$lvm->{size}." -n ".$container." ".$lvm->{vg}); die $! if $?;
		system("mkfs.ext4 /dev/mapper/".$lvm->{vg}."-".$container);          die $! if $?;
	} else {
		warn "info: LVM volume exists (".$container.").\n";	
	} 
	
	# rootfs
	if(! -d $dir->{tmpl_rootfs}) {
		die "Template rootfs (".$dir->{tmpl_rootfs}.") does NOT exist.";
	} else {
		mkdir($dir->{rootfs}) or die;
		chdir($dir->{rootfs}) or die;
		for(qw(bin dev etc lib sbin usr)) {
			my $dst = $_;
			my $src = join('/', $dir->{tmpl_rootfs}, $dst);
			mkdir($dst) or die;
		}
		for(qw( proc sys home 
		        var/cache var/lib var/log var/run 
		        var/spool/cron)) {
			make_path($_) or die;
		}
		symlink('lib','lib64');
		system("mount /dev/mapper/".join('-', $lvm->{vg}, $container)." home"); die $! if $?;
		if(! -d 'home/tmp') {
			mkdir('home/tmp') or die;
		}
		symlink('home/tmp','tmp') or die;
		chmod 01777, 'home/tmp';
		chmod 0711, 'home';
		system("umount /dev/mapper/".join('-', $lvm->{vg}, $container)); die $! if $?;
	}

	chdir($dir->{container});
	
	# lxc.conf 
	my @ipaddr  = split(/\./, $lxc->{network});
	my $i;
	for(reverse @ipaddr) {
		# find zeros in ip
		$_ == 0 ? $i++ : last;
	}	
	
	if($i < 1) {
		die "Wrong network address (".$lxc->{network}."). Check configuration."
	}	
	
	if(length($id) > $i*2) {
		die "ID $id too big for specified network (".$lxc->{network}."). Check configuration.";
	}

	my $netmask = 32 - 8*$i;
	for(my $j=1; $j<=$i; $j++) {
		# get two numbers from the right
		$ipaddr[-$j] = substr($id, -2*$j, 2) || 0;
	}

	open(CONF,'>','lxc.conf');
	print CONF "lxc.utsname = " . $container     . "\n"
	         . "lxc.rootfs = "  . $dir->{rootfs} . "\n"
	         . "lxc.mount = "   . $dir->{fstab}  ."\n"
	         . "lxc.network.hwaddr = 00:FF:" . join(':', map { sprintf('%02d', $_) } @ipaddr) . "\n"
	         . "lxc.network.ipv4 = " . join('.', @ipaddr) . '/' . $netmask . "\n";
	close CONF;
	
	# id 
	open(ID,'>','id');
	print ID $id."\n";
	close ID;
	
	exit 0;
}

sub remove {
	my($self, $container) = @_;
	&is_running($container);
	&umount($container);
	
	if(! -d $dir->{container}) {
		die "Container directory (".$dir->{container}.") does NOT exist.\n";
	} else {
		remove_tree($dir->{container});
	}

	if($lvm->{remove} == 1) {
		my $lv = join('/', $lvm->{vg}, $container);
		system("lvchange -an $lv"); die $! if $?;
		system("lvremove $lv");     die $! if $?;
	}
	exit 0;
}

sub start {
	my($self, $container) = @_;
	&is_running($container);
	
	# container directory
	if(! -d $dir->{container}) {
		die "Container directory (".$dir->{container}.") does NOT exist. Cannot start.";
	} else {
		chdir $dir->{container} or die;
	}
	
	# conf
	if(! -f $dir->{tmpl_conf}) {
		die "lxc.conf template (".$dir->{tmpl_conf}.") does NOT exist.";
	} elsif(! -f 'lxc.conf') {
		die "Container configuration file lxc.conf does NOT exist.";
	} else {
		unlink('log');
		copy($dir->{tmpl_conf}, 'conf') or die;

		# get lxc.conf
		tie my %lxc, "Tie::IxHash";
		open(LXC,'<','lxc.conf');
		while(<LXC>) {
			chomp;
			my($key, $val) = split(/\s*=\s*/, $_);
			next if /^#/;
			next unless defined ($key and $val);
			$lxc{$key} = $val;
		}
		close LXC;		
	
		# alter config file	
		tie my @conf, 'Tie::File', 'conf' or die;
		for(@conf) {
			my($key, $val) = split(/\s*=\s*/, $_);
			next if /^#/ or not defined ($key or $val);
			if(defined $lxc{$key}) {
				s/^$key\s*=.*/$key = $lxc{$key}/;
				delete $lxc{$key};
			}
		}
		
		if(keys %lxc) {
			push @conf, "\n# Other configuration";
			push @conf, map { $_ . ' = ' . $lxc{$_} } keys %lxc;
		}

		untie %lxc;
		untie @conf;
	}
			
	&umount($container);
	&mount($container);
	
	system("lxc-start -n " . $container . " -f conf -o log -l $lxc->{log}");
	exit 0;
}

sub stop {
	my($self, $container) = @_;
	system("lxc-stop -n " . $container);
	&umount($container);
	exit 0;
}

sub help {
	print "\033[1mLXC manager\033[0m by Rootnode\n"
	     ."Usage: $0 start|stop <name>\n"
	     ."       $0 create <name> <id> [<type>]\n"
	     ."       $0 remove <name>\n"
	     ."       $0 template <name>\n\n";

	# list of containers
	my %container;
	foreach my $type ('user', 'system') {
		my $file = join('/',$dir->{$type},'*','id');
		for(glob($file)) {
			my($name) = $_ =~ /^\Q$dir->{$type}\E\/(\w+)\/id$/;
			open(FH,'<',$_);
			my $id = <FH>;
			chomp $id;
			$container{$type}->{$id} = $name;
			close FH;
		}	
	}
	print "\033[1;32mCONTAINERS\033[0m\n";
	if(%container) {
		foreach my $type (keys %container) {
			my %name = %{$container{$type}};
			print "\t\033[1m$type:\033[0m\n\t\t";  
			print join(', ', map { "\033[1;34m" . $name{$_} . "\033[0m (" . $_ . ')' } keys %name);
			print "\n";
		}
	} else {
		print "\tnone";
	}
	print "\n";
	exit 1;
}

sub is_running {
	my $container = shift;
	my %running = map { $_ => 1 } `lxc-ls -1`;
	if(defined $running{$container}) {
		die "Container (".$container.") still running! Stop the container first.";
	} 
	return 1;
}

sub umount {
	my($container) = @_;
	my $type = $lxc->{type};
	open(MOUNT, '<', '/proc/mounts');
	my @mount = <MOUNT>;
	close MOUNT;	
	chomp @mount;
	for(@mount) {
		my($src,$dst) = split(/\s/, $_);
		next unless defined($src and $dst);
		my $path = join('/', $dir->{$type}, $container);
		if($dst =~ /^\Q$path\E\//) {
			system("umount $dst"); die $! if $?;
		}
	}
	return 1;
}

sub mount {
	my($container) = @_;
	my $cwd = cwd();
	chdir $dir->{rootfs} or die;
	my @dirs = qw(bin dev etc lib sbin usr);
	for(@dirs) {
		my $dst = $_;
		my $src = join('/', $dir->{tmpl_rootfs}, $dst);
		if(! -d $dst) {
			die "Directory (".$dst.") does NOT exist.";
		}
		system("mount --bind $src $dst");   
		die $! if $?;
		if($lxc->{$type} =~ /^(ro|read-?only)$/) {
			system("mount -o remount,ro $dst"); 
			die $! if $?;
		}
	}
	system("mount /dev/mapper/" . join('-', $lvm->{vg}, $container) . " home"); die $! if $?;
	chdir $cwd;
	return 1;
}

sub template {
	my($self, $container) = @_;
	chdir($dir->{template}) or die "Cannot access template directory (".$dir->{template}.").";

	if(-d $template->{container}) {
		die "Template container (".$template->{container}.") already exists.";
	} else {
		mkdir($template->{container}, 0700) or die;
		chdir($template->{container});

		# lxc.conf
		copy($template->{tmpl_lxc}, $template->{lxc});
		my $hostname = `hostname`;
		chomp $hostname;
		$hostname = $container.'.template.'.$hostname;
		tie my @lxc, 'Tie::File', $template->{lxc} or die;
		for(@lxc) {
			s/^lxc\.utsname.+/lxc\.utsname = $hostname/;
			s/^lxc\.rootfs.+/lxc\.rootfs = $template->{rootfs}/;
			s/^lxc\.mount.+/lxc\.mount = $template->{fstab}/;
		}
		untie @lxc;

		# fstab
		open(FSTAB,'>','fstab');
  	    	print FSTAB join("\t", 'none', $template->{rootfs}.'/proc', 'proc', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
        	print FSTAB join("\t", 'none', $template->{rootfs}.'/sys', 'sysfs', 'ro,noexec,nosuid,nodev', 0, 0)."\n";
        	close FSTAB;
	}

	# disable chroot restrictions
	my @sysctl = `sysctl -N -a`;
	chomp @sysctl;
	for(@sysctl) {
		if(/^kernel\.grsecurity\.chroot_/) {
			system("sysctl -w ".$_."=0");
			die $! if $?;
		} 
	}
	
	# install debian
	if(! -d $template->{debootstrap}) {
		system("debootstrap --verbose --arch=amd64 " . join(' ', $template->{debian}, $template->{debootstrap}, $template->{repo}));
		die $! if $?;
	}	
	
	system("cp -pr " . $template->{debootstrap} . " " . $template->{rootfs});
	die $! if $?;
	
	# run chroot scripts
	for ('chroot', $lxc->{type}, $container) {
		my $file = join('/', $template->{tmpl_chroot}, $_ . '.sh');
		if($file eq 'chroot.sh' and ! -f $file) {
			die "Cannot find chroot script (".$template->{chroot}."/$file). Check configuration.";
		} elsif(-f $file) {
			print "Running chroot script $file...\n"; sleep 2;
			copy($file, $template->{rootfs}) or die;
			system("chroot ".$template->{rootfs}." /bin/bash /" . basename($file));
			die $! if $?;
			unlink($template->{rootfs} . '/' . basename($file));
		} else {
			print "Script $file not found. Skipping.\n";
		}
	}

	# enable chroot restrictions
	for(@sysctl) {
		if(/^kernel\.grsecurity\.chroot_/) {
			system("sysctl -w ".$_."=1");
			die $! if $?;
		} 
	}
	system("sysctl -p /etc/sysctl.d/lxc.conf");
	die $! if $?;
	exit 0;
}