#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Math::Prime::Util qw/next_prime/;
use Math::BigInt try=>"GMP,Pari";
use Math::BigFloat;
use Carp;

my @incorrect = (
  -4,
  '-',
  '+',
  '++4',
  '+-4',
  '-0004',
  'a',
  '5.6',
  '4e',
  '1.1e12',
  '1e8',
  'NaN',
  Math::BigInt->bnan(),
  Math::BigInt->new("-4"),
  Math::BigFloat->new("15.6"),
);

my %correct = (
  4       => 5,
  '+4'    => 5,
  '0004'  => 5,
  '+0004' => 5,
  5.0     => 7,
  1e8     => 100000007,
  Math::BigInt->new("10000000000000000000000012") => "10000000000000000000000013",
  Math::BigFloat->new("9") => 11,
);

plan tests =>   2                      # undefined and empty string
              + scalar(@incorrect)     # values that should be rejected
              + scalar(keys(%correct)) # values that should be accepted
              + 2                      # infinity and nan
              + 1;                     # long invalid string

eval { next_prime(undef); };
like($@, qr/^Parameter must be defined/, "next_prime(undef)");

eval { next_prime(""); };
like($@, qr/^Parameter must be a positive integer/, "next_prime('')");

foreach my $v (@incorrect) {
  eval { next_prime($v); };
  like($@, qr/^Parameter '\Q$v\E' must be a positive integer/, "next_prime($v)");
}

while (my($v, $expect) = each (%correct)) {
  is(next_prime($v), $expect, "Correct: next_prime($v)");
}

# The actual strings can be implementation specific.
my ($infinity, $nan) = (0+'inf', 0+'nan');
$infinity = Math::BigInt->binf()->numify() if 65535 > $infinity;
$infinity = +(20**20**20) if 65535 > $infinity;
$nan      = Math::BigInt->bnan()->numify() if $nan == 0;
$nan      = -sin($infinity) if $nan == 0;

SKIP: {
  skip "Your machine seems to not have infinity", 1 if 65535 > $infinity;
  eval { next_prime($infinity); };
  like($@, qr/must be a positive integer/, "next_prime( infinity )");
}

SKIP: {
  skip "Your machine seems to not have NaN", 1 if $nan == 0 || $nan =~ /^\d*$/;
  #skip "Skipping NaN test on Win32", 1 if $^O eq 'MSWin32';
  eval { next_prime($nan); };
  like($@, qr/must be a positive integer/, "next_prime( nan ) [nan = '$nan']");
}


SKIP: {
  skip "You need to upgrade either Perl or Carp to avoid invalid non-native inputs from causing a segfault.  Makefile.PL should have requested a Carp upgrade.", 1
    if $] < 5.008 && $Carp::VERSION < 1.17;
  eval { next_prime("11111111111111111111111111111111111111111x"); };
  like($@, qr/must be a positive integer/, "next_prime('111...111x')");
}
