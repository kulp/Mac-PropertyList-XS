#!/usr/bin/perl
# Stolen from Mac::PropertyList (by comdog) for use in Mac::PropertyList::XS (by kulp)
use strict;
use warnings;

use Digest::MD5 qw(md5_hex);

use Test::More tests => 7;

my $Class = 'Mac::PropertyList::XS';
my $suborned = 'Mac::PropertyList::SAX';
use_ok( $Class );

$Class->import( 'parse_plist_file' );

my $File = "plists/com.apple.iTunes.plist";

ok( -e $File, "Sample plist file exists" );

########################################################################
{
ok(
	open( my( $fh ), $File ),
	"Opened $File"
	);

my $plist = parse_plist_file( $fh );

isa_ok( $plist, "${suborned}::dict" );
is( $plist->type, 'dict', 'type key has right value for nested dict' );
my $data = $plist->as_basic_data;
is(md5_hex($data->{"AppleNavServices:ChooseFolder:0:Position"}), "ade49c085386a4e1eeec3df70b3f085a");
is(md5_hex($data->{"RDoc:130:Documents"}), "ac0b29ccf985318d8f9ddbd6ad990dd1");
}

