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
use File::Copy::Recursive qw(dircopy);
use File::Basename qw(basename);
use Tie::File;
use Tie::IxHash;
use Data::Dumper;
use Smart::Comments;
use Cwd;
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
	size   => '6G',         # volume size
	remove => 1             # WARNING! User's /home partition will be removed.
};

my $lxc = {
	network => '10.1.0.0',   # w/o netmask 
	system  => 'rw',         # type of system container
	user    => 'ro',         # type of user   container
	log     => 'INFO',       # log priority
	daemon  => 1             # daemonize lxc-start
};

my $template = {
	debian  => 'squeeze',
	repo    => 'http://ftp.fr.debian.org/debian',
	lxc     => 'lxc.conf',
	key	=> '/root/.ssh/id_rsa.pub'
};

# env
$lvm->{remove} = 1              if defined $ENV{LVM_REMOVE};
$lvm->{size}   = $ENV{LVM_SIZE} if defined $ENV{LVM_SIZE};
$lxc->{daemon} = $ENV{DAEMON}   if defined $ENV{DAEMON};

# main
my($command, $container, $id, $type);
if(@ARGV >= 2) {
	($command, $container, $id, $type) = @ARGV;
	
	# check paths
	foreach my $key (keys %$dir) {
		unless(-d $dir->{$key}) {
			die ucfirst($key)." directory (".$dir->{$key}.") does NOT exist.\n" 
			  . "Change configuration or create directories first.\n"
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
	$lxc->{type} = $type;

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
	help();
}

sub ip {
	my($self,$id) = @_;
	my @ipaddr = get_user_ip($id);	
	pop @ipaddr;
	print join('.', @ipaddr)."\n";
	exit 0;
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
	
	is_running($container);

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
		die "VG (".$lvm->{vg}.") does NOT exist. Check configuration and LVM.\n";
	}
	
	my $lvs = `lvs -olv_name --noheading --rows --unbuffered --aligned --separator=,`;
	   $lvs =~ s/\s+//g;
	my %lvs = map { $_ => 1 } split(/,/, $lvs);

	umount($container);

	if(not defined $lvs{$container}) {
		system("lvcreate -L".$lvm->{size}." -n ".$container." ".$lvm->{vg}); die $! if $?;
		system("mkfs.ext4 -q /dev/mapper/".$lvm->{vg}."-".$container);       die $! if $?;
	} else {
		warn "info: LVM volume exists (".$container.").\n";	
	} 
	
	# rootfs
	if(! -d $dir->{tmpl_rootfs}) {
		die "Template rootfs (".$dir->{tmpl_rootfs}.") does NOT exist.\n";
	} else {
		mkdir($dir->{rootfs}) or die;
		chdir($dir->{rootfs}) or die;
		for(qw(proc sys home)) {
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
		chmod 0700, 'root';
		
		# create and copy directories
		for(qw(bin dev etc root lib sbin usr var)) {
			if($lxc->{type} eq 'user' and $_ =~ /^(var)$/){
				# rw dirs
				my $src = join('/', $dir->{tmpl_rootfs}, $_);
				my $dst = join('/', 'home', $_);
				system("cp -pr $src $dst");
				die $! if $?;
			}
			mkdir($_) or die;
		}

		system("umount /dev/mapper/".join('-', $lvm->{vg}, $container)); die $! if $?;
	}

	chdir($dir->{container});
	
	# lxc.conf 
	my @ipaddr = get_user_ip($id);
	my $netmask = pop @ipaddr;
	my $hostname = `hostname --fqdn`;
	my($server, $domain) = $hostname =~ /^(\w+?)\d+\.([\w.]+)$/;
	open(CONF,'>','lxc.conf');
	print CONF "lxc.utsname = " . join('.', $server, $container, $domain) . "\n"
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
	is_running($container);
	umount($container);
	
	if(! -d $dir->{container}) {
		die "Container directory (".$dir->{container}.") does NOT exist.\n";
	} else {
		remove_tree($dir->{container});
	}

	if($lvm->{remove}) {
		my $lv = join('/', $lvm->{vg}, $container);
		system("lvchange -an $lv"); die $! if $?;
		system("lvremove $lv");     die $! if $?;
	}
	exit 0;
}

sub start {
	my($self, $container) = @_;
	is_running($container);
	
	# container directory
	if(! -d $dir->{container}) {
		die "Container directory (".$dir->{container}.") does NOT exist. Cannot start.\n";
	} else {
		chdir $dir->{container} or die;
	}
	
	# conf
	if(! -f $dir->{tmpl_conf}) {
		die "lxc.conf template (".$dir->{tmpl_conf}.") does NOT exist.\n";
	} elsif(! -f 'lxc.conf') {
		die "Container configuration file lxc.conf does NOT exist.\n";
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
			
	umount($container);
	mount($container);
	etc($container);

	my $daemon = '';
	   $daemon = '-d' if $lxc->{daemon};
	
	system("lxc-start -n " . $container . " -f conf -o log -l $lxc->{log} $daemon");
	exit 0;
}

sub stop {
	my($self, $container) = @_;
	system("lxc-stop -n " . $container);
	umount($container);
	exit 0;
}

sub help {
	print "\033[1mLXC manager\033[0m by Rootnode\n"
	     ."Usage: $0 start|stop <name>\n"
	     ."       $0 create <name> <id> [<type>]\n"
	     ."       $0 remove <name>\n"
	     ."       $0 template <name>\n"
	     ."       $0 ip <id>\n\n";

	# list of containers
	tie my %container, "Tie::IxHash";
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
			print "\t\033[1m$type:\033[0m\n\t\t";  
			my %name = %{$container{$type}};
			my $i;
			for(sort { $a <=> $b } keys %name) {
				$i++;
				print "\033[1;34m" . $name{$_} . "\033[0m (" . $_ . '), ';
				print "\n\t\t" unless $i % 3;
			}
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
	my @ls = `lxc-ls -1`; chomp @ls;
	my %running = map { $_ => 1 } @ls;
	if(defined $running{$container}) {
		die "Container (".$container.") still running! Stop the container first.\n";
	} 
	return 1;
}

sub get_user_ip {
	my($id) = shift;
	my @ipaddr  = split(/\./, $lxc->{network});
	my $i;
	for(reverse @ipaddr) {
		# find zeros in ip
		$_ == 0 ? $i++ : last;
	}	
	
	if($i < 1) {
		die "Wrong network address (".$lxc->{network}."). Check configuration.\n"
	}	
	
	if(length($id) > $i*2) {
		die "ID $id too big for specified network (".$lxc->{network}."). Check configuration.\n";
	}

	my $netmask = 32 - 8*$i;
	for(my $j=1; $j<=$i; $j++) {
		# get two numbers from the right
		$ipaddr[-$j] = int substr($id, -2*$j, 2) || 0;
	}
	push @ipaddr, $netmask;
	return @ipaddr;
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

sub etc {
	my ($container) = @_;
	my $cwd = cwd();
		
	# proceed only if user type
	if ($lxc->{type} ne 'user') {
		return;
	}	
	
	# /etc paths
	my $container_path = "$dir->{rootfs}/home/etc";
	my $template_path  = "$dir->{tmpl_rootfs}/home/etc";
	
	# get files from container dir	
	chdir $container_path or return;
	my @container_files = glob('*');

	# get files from template dir
	chdir $template_path or die;
	my @template_files = glob('*');

	# strore container files as hashmap
	my %in_container = map { $_ => 1 } @container_files;

	### @container_files
	### @template_files
	
	# compare arrays and copy lacking files
	foreach my $file_name (@template_files) {
		if (!$in_container{$file_name}) {
			# is directory
			if (-d "$template_path/$file_name") {
				### directory: $file_name
				dircopy("$template_path/$file_name", "$container_path/$file_name") 
					or die "Cannot copy file $file_name: $!";
			} 
			# is file
			else {
				### file: $file_name
				copy("$template_path/$file_name", "$container_path/$file_name") 
					or die "Cannot copy file $file_name: $!";
			}
		}
	}	
	
	chdir $cwd;
	return; 
}

sub mount {
	my($container) = @_;
	my $cwd = cwd();
	my $type = $lxc->{type};
	chdir $dir->{rootfs} or die;

	# mount home
	system("mount -o nodev,nosuid /dev/mapper/" . join('-', $lvm->{vg}, $container) . " home"); 
	die $! if $?;

	# mount dirs
	for(qw(bin dev etc root lib sbin usr var)) {
		my $dst = $_;
		my $src;
		if($lxc->{type} eq 'user' and $dst =~ /^(var)$/) {
			# rw dirs
			$src = join('/', $dir->{rootfs}, 'home', $dst);
		} else {
			$src = join('/', $dir->{tmpl_rootfs}, $dst);
		}

		if(! -d $dst) {
			die "Directory (".$dst.") does NOT exist.\n";
		}

		if($dst eq 'var') {
			system("mount -o noexec,nodev,nosuid --bind $src $dst");
		} else {
			system("mount --bind $src $dst");   
		}
		die $! if $?;

		if($lxc->{$type} =~ /^(ro|read-?only)$/) {
			unless ($lxc->{type} eq 'user' and $dst =~ /^(var)$/) {	
				system("mount -o remount,ro $dst"); 
				die $! if $?;
			}
		}
	}
		
	chdir $cwd;
	return 1;
}

sub template {
	my($self, $container) = @_;
	chdir($dir->{template}) or die "Cannot access template directory (".$dir->{template}.").\n";

	if(-d $template->{container}) {
		die "Template container (".$template->{container}.") already exists.\n";
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

	# ssh key
	if(! -f $template->{key}) {
		die "Cannot find SSH public key (".$template->{key}."). Run 'ssh -b 4096 -t rsa' command.\n";
	} else {
		my $ssh_dir = join('/', $template->{rootfs}, 'root/.ssh');
		make_path($ssh_dir, { mode => 0700 }) or die;
		copy($template->{key}, $ssh_dir . '/' . 'authorized_keys');
	}

	# run chroot scripts
	for ('chroot', $lxc->{type}, $container) {
		my $file = join('/', $template->{tmpl_chroot}, $_ . '.sh');
		if($file =~ /\/chroot.sh$/ and ! -f $file) {
			die "Cannot find chroot script (".$file."). Check configuration.\n";
		} elsif(-f $file) {
			print "Running chroot script $file...\n"; sleep 2;
			copy($file, $template->{rootfs}) or die;
			system('chroot '.$template->{rootfs}.' /bin/bash /' . basename($file) . ' ' . $container);
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
