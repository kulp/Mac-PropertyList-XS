# Stolen from Mac::PropertyList (by comdog) for use in Mac::PropertyList::XS (by kulp)

use Test::More tests => 2;

use Mac::PropertyList::XS;

########################################################################
# Test the dict bits
my $dict = Mac::PropertyList::dict->new();
isa_ok( $dict, "Mac::PropertyList::dict" );

########################################################################
# Test the array bits
my $array = Mac::PropertyList::array->new();
isa_ok( $array, "Mac::PropertyList::array" );
