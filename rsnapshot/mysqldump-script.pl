#!/usr/bin/perl
#
# Rsnapshot mysqldump script
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use Readonly;
use File::Basename qw(basename);
use Smart::Comments;
$|++;

Readonly my $MYSQLDUMP_BIN     => '/usr/bin/mysqldump';
Readonly my $MYSQLDUMP_OPTIONS => '--opt --default-character-set=utf8';
Readonly my $MYSQLDUMP_SUFFIX  => 'sql.gz';

Readonly my $GZIP_BIN   => '/usr/bin/gzip';
Readonly my $GZIP_LEVEL => 9;

Readonly my $BASENAME => basename($0);
Readonly my $USAGE    => <<END_OF_USAGE;
Rsnapshot mysqldump script
Usage:
	$BASENAME <db_name>...

All configuration options inside the script.
Script uses 127.0.0.1:3306 for MySQL connection.
SSH tunnel recommended (daemontools+autossh).

END_OF_USAGE

die $USAGE if !@ARGV;

DUMP:
foreach my $db_name (@ARGV) {
	chomp $db_name;
	system("$MYSQLDUMP_BIN $MYSQLDUMP_OPTIONS $db_name | $GZIP_BIN -$GZIP_LEVEL > $db_name.$MYSQLDUMP_SUFFIX");
}

exit 0;
