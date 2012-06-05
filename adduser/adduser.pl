#!/usr/bin/perl
#
# Adduser script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
# 
# Get user data from signup database
# Create PAM+Satan user
# Insert user data into adduser database
# Assign servers to user
# Create containers with lxc-add remote script

use warnings;
use strict;
use Readonly;
use FindBin qw($Bin);
use File::Basename qw(basename);
use POSIX qw(isdigit);
use DBI;
use Getopt::Long;
use Smart::Comments;

# Server ID's
Readonly my $WEB_SERVER_ID => 1;
Readonly my $APP_SERVER_ID => 1;
Readonly my $DEV_SERVER_ID => 1;

# Satan connection params
Readonly my $SATAN_ADDR  => '10.101.0.5';
Readonly my $SATAN_PORT  => '1600';
Readonly my $SATAN_KEY   => '/etc/satan/key';
Readonly my $SATAN_BIN   => '/usr/local/bin/satan';

# SSH params
Readonly my $SSH_BIN         => '/usr/bin/ssh';
Readonly my $SSH_ADD_KEY     => '/root/.ssh/lxc_add_rsa';
Readonly my $SSH_ADD_COMMAND => '/usr/local/sbin/lxc-add';

# Usage
Readonly my $BASENAME => basename($0);
Readonly my $USAGE => <<END_OF_USAGE;
Adduser script
Usage:
	$BASENAME signup                     
	$BASENAME pam --uid <uid>
	$BASENAME container --uid <uid>
END_OF_USAGE

# Check configuration
-f $SATAN_BIN   or die "\$SATAN_BIN ($SATAN_BIN) not found.\n";
-f $SATAN_KEY   or die "\$SATAN_KEY ($SATAN_KEY) not found.\n";
-f $SSH_ADD_KEY or die "\$SSH_ADD_KEY ($SSH_ADD_KEY) not found.\n";

# Signup database
my %db_signup;
   $db_signup{dbh} = DBI->connect("dbi:mysql:signup;mysql_read_default_file=$Bin/config/my.signup.cnf", undef, undef, { RaiseError => 1, AutoCommit => 1 });
	
   $db_signup{get_user}   = $db_signup{dbh}->prepare("SELECT * FROM users WHERE status IS NULL LIMIT 1");
   $db_signup{del_user}   = $db_signup{dbh}->prepare("DELETE FROM users WHERE id=?");
   $db_signup{set_status} = $db_signup{dbh}->prepare("UPDATE users SET status=? WHERE id=?");

# Adduser database
my %db_adduser;
   $db_adduser{dbh} = DBI->connect("dbi:mysql:adduser;mysql_read_default_file=$Bin/config/my.adduser.cnf", undef, undef, { RaiseError => 1, AutoCommit => 1 });

   $db_adduser{add_user} = $db_adduser{dbh}->prepare("INSERT INTO users (uid, user_name, mail, created_at) VALUES(?,?,?, NOW())");
   $db_adduser{get_user} = $db_adduser{dbh}->prepare("SELECT * FROM users WHERE uid=?");

   $db_adduser{add_credentials} = $db_adduser{dbh}->prepare("INSERT INTO credentials(uid, satan_key, pam_passwd, pam_shadow, user_password, user_password_p) VALUES(?,?,?,?,?,?)");
   $db_adduser{get_credentials} = $db_adduser{dbh}->prepare("SELECT * FROM credentials WHERE uid=?");

   $db_adduser{add_container}        = $db_adduser{dbh}->prepare("INSERT INTO containers(uid, server_type, server_no) VALUES(?,?,?)");
   $db_adduser{get_container}        = $db_adduser{dbh}->prepare("SELECT server_no FROM containers WHERE uid=? AND server_type=? and status is NULL");
   $db_adduser{set_container_status} = $db_adduser{dbh}->prepare("UPDATE containers SET status=? WHERE uid=? AND server_type=?");

# Get arguments
die $USAGE unless @ARGV;
my $mode_type = shift or die "Mode not specified. Use 'signup', 'container' or 'pam'.\n";

# Get command line arguments
my ($opt_uid, $opt_server);
GetOptions(
	'uid=i'    => \$opt_uid,
	'server=s' => \$opt_server, 
);

# SIGNUP MODE
# Get 1 user from signup database
# Create Pam+Satan user
# Store data in adduser database	
if ($mode_type eq 'signup') {
	# Get one record from signup database
	$db_signup{get_user}->execute;

	# Exit if nothing found
	my $record_found = $db_signup{get_user}->rows;
	   $record_found or exit;

	# Get user data
	my $signup_record = $db_signup{get_user}->fetchall_hashref('user_name');
	### $signup_record

	# Get username
	my @user_names = keys %$signup_record;
	my $user_name  = shift @user_names;
	### $user_name

	# User record
	my $user_record = $signup_record->{$user_name};
	### $user_record

	# Add PAM+Satan user
	my $satan_response;
	eval { 
		$satan_response = satan('admin', 'adduser', $user_name);
	};

	# Satan error
	if ($@) {
		my $error_message = $@;
		chomp $error_message;
		my $user_id = $user_record->{id};
		$db_signup{set_status}->execute($error_message, $user_id);
		die "Satan error: $@";
	}
	
	my $uid = $satan_response->{uid} or die "Didn't get uid from satan";

	### $satan_response

	# XXX Catch satan error
        # $db_signup{set_status}->execute($error_message, $user_record->{id});

	# Add record to adduser database
	$db_adduser{add_user}->execute(
		$uid,
		$user_record->{user_name},
		$user_record->{mail},
	);
	
	# Insert user credentials
	$db_adduser{add_credentials}->execute(
		$uid,
		$satan_response->{satan_key},
		$satan_response->{pam_passwd},
		$satan_response->{pam_shadow},
		$satan_response->{user_password},
		$satan_response->{user_password_p}
	);

	# Assign servers
	set_containers($uid);

	# Remove record from signup database
	$db_signup{del_user}->execute($user_record->{id});

	exit;	
}

# PAM MODE
# Create pam and satan user only.
if ($mode_type eq 'pam') {
	# Mandatory arguments
	defined $opt_uid or die "Uid not specified.";
	my $uid = $opt_uid;
	
	# Get user from adduser database
	$db_adduser{get_user}->execute($uid);
	my $user_found = $db_adduser{get_user}->rows;
	   $user_found or die "Uid '$uid' not found in adduser database.\n";

	# User record
	my $user_record = $db_adduser{get_user}->fetchall_hashref('uid')->{$uid};
	my $user_name = $user_record->{user_name} or die "User name not found";

	# Add PAM+Satan user with predefined uid
	my $satan_response = satan('admin', 'adduser', $user_name, 'uid', $uid);

	# Insert user credentials
	$db_adduser{add_credentials}->execute(
		$uid,
		$satan_response->{satan_key},
		$satan_response->{pam_passwd},
		$satan_response->{pam_shadow},
		$satan_response->{user_password},
		$satan_response->{user_password_p}
	);
	
	# Assign servers to user
	set_containers($uid);
	exit;
}

# CONTAINER MODE
# Create user container on specified server.
# User must exist in adduser database.
if ($mode_type eq 'container') {
	# Mandatory arguments
	defined $opt_uid    or die "Uid not specified.";
	defined $opt_server or die "Server name not specified."; 

	my $uid = $opt_uid;
	my $server_type = $opt_server;

	# Get user from adduser database
	$db_adduser{get_user}->execute($uid);
	my $user_found = $db_adduser{get_user}->rows;
	   $user_found or die "Uid '$uid' not found in adduser database.\n";

	# User record
	my $user_record = $db_adduser{get_user}->fetchall_hashref('uid')->{$uid};
	my $user_name = $user_record->{user_name} or die "User name not found";

	### $user_name

	# Get credentials
	$db_adduser{get_credentials}->execute($uid);
	my $credentials_found = $db_adduser{get_credentials}->rows;
	   $credentials_found or die "Uid '$uid' not found in database.\n";

	my $credentials = $db_adduser{get_credentials}->fetchall_hashref('uid')->{$uid};

	# Get container number
	$db_adduser{get_container}->execute($uid, $server_type);
	my $server_found = $db_adduser{get_container}->rows;
	   $server_found or die "Container type '$server_type' not defined for user '$uid'.\n";

	my $server_no = $db_adduser{get_container}->fetchrow_arrayref->[0];
	isdigit($server_no) or die "Server no '$server_no' not a number.\n";
	
	my $server_name = $server_type . $server_no;
	
	# Set SSH command arguments
	my $command_args = "satan_key $credentials->{satan_key} "
			 . "pam_passwd $credentials->{pam_passwd} "
			 . "pam_shadow $credentials->{pam_shadow} "
			 . "uid $uid "
	                 . "user_name $user_name";

	### $command_args
	system("$SSH_BIN -i $SSH_ADD_KEY root\@system.$server_name.rootnode.net $SSH_ADD_COMMAND $command_args");
	
	if ($?) {
		my $error_message = $!;
		chomp $error_message;
		$db_adduser{set_container_status}->execute($error_message, $uid, $server_type);
		die "lxc-add failed: $!";
	}

	$db_adduser{set_container_status}->execute('OK', $uid, $server_type);
	exit;
}

die "Unknown mode '$mode_type'. Cannot proceed.\n";

sub set_containers {
	my ($uid) = @_;
	defined $uid or die "Uid not defined in set_servers sub";

	# Set server IDs
	my %server_no_for = (
		web => $WEB_SERVER_ID,
		app => $APP_SERVER_ID,
		dev => $DEV_SERVER_ID,
	);	

	# Assing servers to user
	foreach my $server_type (keys %server_no_for) {
		# Get server number
		my $server_no = $server_no_for{$server_type};
			
		# Add server to database
		$db_adduser{add_container}->execute(
			$uid,
			$server_type,
			$server_no
		);
	}

	return;
}

sub satan {
	local @ARGV;

	# Satan arguments
	push @ARGV, '-a', $SATAN_ADDR if defined $SATAN_ADDR;
	push @ARGV, '-p', $SATAN_PORT if defined $SATAN_PORT;
	push @ARGV, '-k', $SATAN_KEY  if defined $SATAN_KEY;
	push @ARGV, @_;
	
	# Send to satan
	my $response = do $SATAN_BIN;

	# Catch satan error
	if ($@) {
		my $error_message = $@;
		die "Cannot proccess $@";
	}
	
	return $response;
}

sub do_rollback {
	my ($error_message, $user_id) = @_;
	$db_signup{set_status}->execute($error_message, $user_id);
}

exit;
