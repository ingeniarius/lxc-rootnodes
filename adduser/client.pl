#!/usr/bin/perl -l
#
# Satan (client)
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
use strict;
use warnings;
use feature 'switch';
use JSON::XS;
use IO::Socket;
use Getopt::Long;
use Readonly;
use Data::Dumper;

# configuration
Readonly my $SATAN_ADDR => '10.1.0.6';
Readonly my $SATAN_PORT => '1600';
Readonly my $SATAN_KEY  => '/etc/satan/key';

# options
my ($opt_key, $opt_debug, $opt_verbose, $opt_help);
GetOptions (
	'key=s'   => \$opt_key,
	'debug'   => \$opt_debug,
	'verbose' => \$opt_verbose,
	'help'    => \$opt_help,
);

# json serialization
my $json = JSON::XS->new->utf8;

# connect to satan 
my $s_client = new IO::Socket::INET ( 
	PeerAddr => $SATAN_ADDR,
	PeerPort => $SATAN_PORT,
	Timeout  => 1,
) or die "Could not connect to Satan! $!.\n";

sub auth {
	my ($file_name) = @_;
	
	# open credentials file
	-f $file_name or die "Cannot find credentials file ($file_name).\n"; 
	open my $fh, '<', $file_name or die "Cannot open user credentials file ($file_name).\n";

	# store login and password as array
	my @credentials = split /\s/, <$fh>;

	# send request to satan
	request(\@credentials);

	return;
}

sub debug {
	my ($data_ref) = { @_ };

	# get caller info
	my $caller = (caller 2)[3] || '';
	return if $caller eq 'main::auth';

	# show perl structures in debug mode
	if ($opt_debug) {
		# avoid VAR names in Dumper output
		$Data::Dumper::Terse = 1;
		
		# print to STDERR
		print STDERR "\033[1;32mRequest:\033[0m  " . Dumper($data_ref->{request})  if $data_ref->{request};
		print STDERR "\033[1;31mResponse:\033[0m " . Dumper($data_ref->{response}) if $data_ref->{response}; 
	}

	# show json data in verbose mode
	if ($opt_verbose) {
		print STDERR "\033[1;32mRequest:\033[0m  " . $data_ref->{json_request}  if $data_ref->{json_request};
		print STDERR "\033[1;31mResponse:\033[0m " . $data_ref->{json_response} if $data_ref->{json_response}; 
	}

	return;
}

sub request {
	my ($request) = @_;

	# exit if no request
	die "Empty request!" unless defined $request;

	# encode to json
	my $json_request = $json->encode($request);
	
	# send request
	print $s_client $json_request;

	# get response
	my $json_response = scalar <$s_client> or die "Could not connect to Satan!\n";
	chomp $json_response;

	# decode json
	my $response = $json->decode($json_response);
	
	# show debug
	debug(
		response      => $response,
		request       => $request,
		json_response => $json_response,
		json_request  => $json_request
	);

	# show message and exit if status != 0
	if ($response->{status}) {
		# print additional line in debug mode
		if ($opt_verbose or $opt_debug) {
			print STDERR "\n\033[1mSatan output:\033[0m";
		}
	
		# print message end exit with non-zero status code
		print STDERR $response->{message};

		# trim status code to first digit
		my $status_code = substr($response->{status}, 0, 1);
	
		# exit with non-zero status code
		exit $status_code;
	}

	return $response;
}

# get command name
my $command_name = $ARGV[0] || 'help';

# authenticate
auth($opt_key || $SATAN_KEY);

# send command
my $response = request(\@ARGV);

# get data
my $data = $response->{data};

# display data
if (defined $data) {
	# return perl structure if called from another script
	return $data if caller();
	
	# print additional line in debug mode
	if ($opt_verbose or $opt_debug) {
		print "\n\033[1mSatan output:\033[0m";	
	}

	# print keys and values if admin request
	if ($command_name eq 'admin') {
		print join q{ }, @{ [ %$data ] }; 
	} 
	else {
		print $data;
	}
}

exit;
