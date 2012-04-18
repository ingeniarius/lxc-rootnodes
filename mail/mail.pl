#!/usr/bin/perl
#
# Mail sender 
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use strict;
use warnings;
use Getopt::Long;
use Email::Send;
use Encode::MIME::Header;
use Encode qw(encode decode);
use Readonly;
use Data::Validate::Email qw(is_email);
use Data::Dumper;
$|++;

# configuration
Readonly my $FROM => 'Marcin Hłybin <marcin@rootnode.net>';
Readonly my $SMTP => 'localhost';
Readonly my $HEADERS => <<EOF;
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Disposition: inline
Content-Transfer-Encoding: 8bit
X-Rootnode-Powered: I am so proud you are reading this!
EOF

Readonly my $USAGE => <<EOF;
\033[1mUsage:\033[0m $0 -s <subject> [-t] <recipient> [-f] <file> [<key>=<val>...]  

\033[1;32mOPTIONS\033[0m
  -s, --subject         Message subject
  -t, --to              Recipient e-mail address
  -f, --file            Template/message file
  -l, --lang            Template language
  -h, --help            Show help

\033[1;32mEXAMPLE\033[0m
$0 -s 'Password change' -f templates/passwd.tmpl -t recipient\@mail.com login=myuser password=pass1 
cat mail.txt | $0 -s 'Important message' user\@domain.com

EOF

sub in_utf8 { 
	my ($string) = shift;
	return encode("MIME-Header", decode('utf8', $string));
}

# get command line options
my ($subject, $file, $body, $headers, $to, $lang, $help);
GetOptions (
	'subject=s' => \$subject,
	'file=s'    => \$file,
	'to=s'      => \$to,
	'lang=s'    => \$lang,
	'help'      => \$help
);

# show usage
if ($help) {
	print $USAGE;
	exit 1;
}


# recipient
if (not defined $to) {
	$to = shift;
}

die "Recipient not defined. Cannot proceed.\n" if not defined $to;
is_email($to) or die "Recipient $to is not a proper e-mail address.\n";

# read mail body from file
$file = $file || shift;
if (defined $file and $file ne '-') {
	# template language
	if (defined $lang) {
		my ($template_name) = $file =~ /\A(.+)(?:_$lang)?\.tmpl\z/;
	   	   $file = "$template_name\_$lang.tmpl";
		-f $file or die "Template file $file not found. Cannot proceed.\n";
	}
	open my $fh, '<', $file or die "File $file not found. Cannot proceed.\n";
	local $/;
	$body = <$fh>;
	close $fh;
} 
else {
	# use STDIN
	local $/;
	$body = <>;
}

# get template variables from command line
my %var;
for (@ARGV) {
	my ($key, $val) = split /=/;
	next if not defined $key or not defined $val; 
	next if $key eq '' or $val eq '';
	$var{$key} = $val;	
}

# convert template
map { $body =~ s/%%\Q$_\E%%/$var{$_}/gi; } keys %var;

# check if everything done
if ($body =~ /%%.+%%/) {
	die "Not all variables from template are specified in command line. Cannot proceed.\n";
}

# subject
if (not defined $subject) {
	($subject) = $body =~ /^#Subject: (.+?)$/m;
	die "Subject not defined. Cannot proceed.\n" if not defined $subject;
}
$body =~ s/^#Subject: .*?\n//; # trim subject line

# trim empty lines in the beginning
$body =~ s/^\n+//;

# message headers
$headers .= $HEADERS;
$headers .= 'To: '      . in_utf8($to)      . "\n";
$headers .= 'From: '    . in_utf8($FROM)    . "\n";
$headers .= 'Subject: ' . in_utf8($subject) . "\n";

# compose message
my $message = join("\n", $headers, $body);

# send message
print "Sending message to $to ";
my $mail = Email::Send->new({mailer => 'SMTP'});
   $mail->mailer_args([Host => 'localhost']);
   $mail->send(decode('utf8', $message)) ? print "(done)\n" : print "(FAIL)\n";
   print "$@";

exit;
