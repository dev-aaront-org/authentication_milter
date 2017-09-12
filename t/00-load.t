#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Mail::Milter::Authentication::Handler::ARC' ) || print "Bail out! ";
}

diag( "Testing Mail::Milter::Authentication::Handler::ARC $Mail::Milter::Authentication::Handler::ARC::VERSION, Perl $], $^X" );

