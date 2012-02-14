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
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use Tie::IxHash;
use Data::Dumper;

# configuration
my $dir = {
	template => '/lxc/template/client',
	user     => '/lxc/client',
	system   => '/lxc/system',
	bin      => '/lxc/scripts'
};

my $lvm = {
	vg     => 'lxc',
	size   => '10G',
	remove => 1      # WARNING! It will remove user's /home volume.
};

my $lxc = {
	mode    => 'client',    # 'client', 'system' or 'rootnode'
	network => '10.10.0.0', # w/o netmask 
};

my $template = {
	dir    => '/lxc/template',
	debian => 'squeeze',
	repo   => 'http://ftp.fr.debian.org/debian',
	script => 'chroot.sh',
	lxc    => 'lxc.conf'
};

# main
my($command, $container, $id);
if(@ARGV >= 2) {
	($command, $container, $id) = @ARGV;
	
	# check paths
	unless($command eq 'template') {
		foreach my $key (keys %$dir) {
			unless(-d $dir->{$key}) {
				die ucfirst($key)." directory (".$dir->{$key}.") does NOT exist.\n" 
				  . "Change configuration or create directories first."
			}
		}
	}
	
	# directories and files
	$dir->{container}   = join('/', $dir->{user},        $container);
	$dir->{fstab}       = join('/', $dir->{container},   'fstab');
	$dir->{rootfs}      = join('/', $dir->{container},   'rootfs');
	$dir->{tmpl_rootfs} = join('/', $dir->{template},    'rootfs');
	$dir->{tmpl_etc}    = join('/', $dir->{tmpl_rootfs}, 'etc');
	$dir->{tmpl_conf}   = join('/', $dir->{template},    'lxc.conf');
	
	$template->{container}   = join('/', $template->{dir}, $container);
	$template->{debootstrap} = join('/', $template->{dir}, 'debootstrap-debian_'.$template->{debian});
	$template->{rootfs}      = join('/', $template->{container}, 'rootfs');
	$template->{tmpl_chroot} = join('/', $dir->{bin}, $template->{script});
	$template->{tmpl_lxc}    = join('/', $dir->{bin}, $template->{lxc}); 

	__PACKAGE__->$command($container,$id);
} else {
	&help;
}

sub create {
	my($self, $container, $id) = @_;
	if(not defined $id) {
		die "ID not defined. See help.";
	}
	
	&is_running($container);

	# container directory
	if(-d $dir->{container}) {
		die "Container already exists (".$dir->{container}."). Remove container first.";
	} else {
		make_path($dir->{container}) or die;
	}

	chdir($dir->{container});
	
	# fstab
	open(FSTAB,'>',$dir->{fstab});
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
		warn "LVM volume exists (".$container.").\n";	
	} 
	
	# rootfs
	if(! -d $dir->{tmpl_rootfs}) {
		die "Template rootfs (".$dir->{tmpl_rootfs}.") does NOT exist.";
	} else {
		mkdir($dir->{rootfs}) or die;
		chdir($dir->{rootfs}) or die;
		for(qw(bin dev lib sbin usr)) {
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
		
		# create /etc
		if($lxc->{mode} ne 'rootnode') {
			if(! -d 'home/etc') {
				system("cp -pr ".$dir->{tmpl_etc}." home/etc");
				die $! if $?;
			}
			symlink('home/etc', 'etc') or die;
		} else {
			mkdir('etc') or die;	
		}
		
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
		die "Container directory (".$dir->{container}.") does NOT exist.";
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
		chdir $dir->{container};
	}
	
	# conf
	if(! -f $dir->{tmpl_conf}) {
		die "lxc.conf template (".$dir->{tmpl_conf}.") does NOT exist.";
	} elsif(! -f 'lxc.conf') {
		die "Configuration file lxc.conf doess NOT exist.";
	} else {
		unlink('conf') if -f 'conf';
		copy($dir->{tmpl_conf}, 'conf') or die;

		# get lxc.conf
		my %lxc;
		tie %lxc, "Tie::IxHash";
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
		open(CONF,'+<','conf');
		my @conf = <CONF>;
		for(@conf) {
			chomp;
			my($key, $val) = split(/\s*=\s*/, $_);
			next if /^#/;
			next unless defined ($key and $val);
			if(defined $lxc{$key}) {
				s/^$key\s*=.*/$key = $lxc{$key}/;
				delete $lxc{$key};
			}
		}
		
		if(keys %lxc) {
			push @conf, "\n# Other configuration";
			push @conf, map { $_ . ' = ' . $lxc{$_} } keys %lxc;
		}
		print CONF join("\n", @conf)."\n";	
		close CONF;
	}
			
	&umount($container);
	&mount($container);
	
	chdir $dir->{container} or die;
	system("lxc-start -n " . $container . " -f conf -o log -l INFO");
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
	     ."       $0 create <name> <id>\n"
	     ."       $0 remove <name>\n"
	     ."       $0 template <name>\n\n";

	# list of containers
	my %container;
	my $file = join('/',$dir->{user},'*','id');
	for(glob($file)) {
		my($name) = $_ =~ /^\Q$dir->{user}\E\/(\w+)\/id$/;
		open(FH,'<',$_);
		my $id = <FH>;
		chomp $id;
		$container{$id} = $name;
		close FH;
	}	
	print "\033[1;32mContainer list: \033[0m";
	print map { join( ', ', $container{$_}.' ('.$_.')' ) } keys %container;
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
	my $container = shift;
	open(MOUNT, '<', '/proc/mounts');
	while(<MOUNT>) {
		chomp;
		my($src,$dst) = split(/\s+/, $_);
		my $path = join('/', $dir->{user}, $container);
		if($dst =~ /^\Q$path\E\//) {
			system("umount $dst"); die $! if $?;
		}
	}
	close MOUNT;	
	return 1;
}

sub mount {
	my $container = shift;
	chdir $dir->{rootfs} or die;
	my @dirs = qw(bin dev lib sbin usr);
	if($lxc->{mode} eq 'rootnode') {
		push @dirs, 'etc';		
	}
	for(@dirs) {
		my $dst = $_;
		my $src = join('/', $dir->{tmpl_rootfs}, $dst);
		if(! -d $dst) {
			die "Directory (".$dst.") does NOT exist.";
		}
		system("mount --bind $src $dst");   die $! if $?;
		system("mount -o remount,ro $dst"); die $! if $?;
	}

	system("mount /dev/mapper/" . join('-', $lvm->{vg}, $container) . " home"); die $! if $?;
	return 1;
}

sub template {
	my($self, $container) = @_;
	chdir($template->{dir}) or die "Cannot access template directory (".$template->{dir}.").";

	if(-d $template->{container}) {
		die "Template container (".$template->{container}.") already exists.";
	} else {
		mkdir($template->{container}, 0700) or die;
		chdir($template->{container});
		copy($template->{tmpl_lxc}, $template->{lxc});
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
	
	# run chroot script
	if(! -f $template->{tmpl_chroot}) {
		system("pwd");
		die "Cannot find chroot script (".$template->{tmpl_chroot}."). Check configuration.";
	} else {
		copy($template->{tmpl_chroot}, $template->{rootfs}) or die;
		system("chroot ".$template->{rootfs}." /bin/bash /".$template->{script});
		die $! if $?;
		unlink($template->{rootfs}.'/'.$template->{script});
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
