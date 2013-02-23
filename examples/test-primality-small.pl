#!/usr/bin/env perl
use strict;
use warnings;
$| = 1;  # fast pipes

# Make sure the is_prob_prime functionality is working for small inputs.
# Good for making sure the first few M-R bases are set up correctly.

use Math::Prime::Util qw/is_prob_prime/;
use Math::Primality qw/next_prime/;

# Test just primes
if (0) {
  my $n = 2;
  my $i = 1;
  while ($n < 100_000_000) {
    die "$n" unless is_prob_prime($n);
    $n = next_prime($n);  $n = int("$n");
    #print "." unless $i % 16384;
    print "$i $n\n" unless $i++ % 16384;
  }
}

# Test every number up to the 100Mth prime (about 2000M)
if (1) {
  my $n = 2;
  foreach my $i (2 .. 100_000_000) {
    die "$n should be prime" unless is_prob_prime($n);
    print "$i $n\n" unless $i % 262144;
    my $next = next_prime($n);  $next = int("$next");
    my $diff = ($next - $n) >> 1;
    if ($diff > 1) {
      foreach my $d (1 .. $diff-1) {
        my $cn = $n + 2*$d;
        die "$cn should be composite" if is_prob_prime($cn);
      }
    }
    $n = $next;
  }
}
