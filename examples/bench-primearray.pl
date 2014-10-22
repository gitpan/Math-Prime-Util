#!/usr/bin/env perl
use strict;
use warnings;
use Math::Prime::Util qw/:all/;
use Math::Prime::Util::PrimeArray;
use Math::NumSeq::Primes;
use Math::Prime::TiedArray;
use Benchmark qw/:all/;
use List::Util qw/min max/;
my $count = shift || -2;

my ($s, $nlimit, $ilimit, $expect);

if (1) {
print "summation to 100k\n";
$nlimit = 100000;
$ilimit = prime_count($nlimit)-1;
$expect = 0; forprimes { $expect += $_ } $nlimit;

cmpthese($count,{
  'primes'    => sub { $s=0; $s += $_ for @{primes($nlimit)}; die unless $s == $expect; },
  'forprimes' => sub { $s=0; forprimes { $s += $_ } $nlimit;  die unless $s == $expect; },
  'iterator'  => sub { $s=0; my $it = prime_iterator();
                       $s += $it->() for 0..$ilimit;
                       die unless $s == $expect; },
  'pa index'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $primes[$_] for 0..$ilimit;
                       die unless $s == $expect; },
  'pa loop'   => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       for (@primes) { last if $_ > $nlimit; $s += $_; }
                       die $s unless $s == $expect; },
  'pa slice'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $_ for @primes[0..$ilimit];
                       die unless $s == $expect; },
  'pa each'   => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       while(my(undef,$v) = each @primes) { last if $v > $nlimit; $s += $v; }
                       die $s unless $s == $expect; },
  'pa shift'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       while ((my $p = shift @primes) <= $nlimit) { $s += $p; }
                       die unless $s == $expect; },
  'numseq'    => sub { $s=0; my $seq = Math::NumSeq::Primes->new;
                       while (1) { my($undev,$v) = $seq->next; last if $v > $nlimit; $s += $v; }
                       die $s unless $s == $expect; },
  # This was slightly faster than slice or shift
  'tiedarray'  => sub { $s=0; tie my @primes, "Math::Prime::TiedArray", extend_step => 1000;
                       $s += $primes[$_] for 0..$ilimit;
                       die unless $s == $expect; },
});
}

if (0) {
print "summation to 10M\n";
print "Skipping Math::Prime::TiedArray as it will take too long\n";
$nlimit = 10_000_000;
$ilimit = prime_count($nlimit)-1;
$expect = 0; forprimes { $expect += $_ } $nlimit;

cmpthese($count,{
  'primes'    => sub { $s=0; $s += $_ for @{primes($nlimit)}; die unless $s == $expect; },
  'forprimes' => sub { $s=0; forprimes { $s += $_ } $nlimit;  die unless $s == $expect; },
  'pa index'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $primes[$_] for 0..$ilimit;
                       die unless $s == $expect; },
  'pa loop'   => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       for (@primes) { last if $_ > $nlimit; $s += $_; }
                       die $s unless $s == $expect; },
  'pa slice'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $_ for @primes[0..$ilimit];
                       die unless $s == $expect; },
  'pa each'   => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       while(my(undef,$v) = each @primes) { last if $v > $nlimit; $s += $v; }
                       die $s unless $s == $expect; },
  'pa shift'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       while ((my $p = shift @primes) <= $nlimit) { $s += $p; }
                       die unless $s == $expect; },
  'numseq'    => sub { $s=0; my $seq = Math::NumSeq::Primes->new;
                       while (1) { my($undev,$v) = $seq->next; last if $v > $nlimit; $s += $v; }
                       die $s unless $s == $expect; },
});
}

if (1) {
print "Walk primes backwards from 1M\n";
$nlimit = 1_000_000;
$ilimit = prime_count($nlimit)-1;
$expect = 0; forprimes { $expect += $_ } $nlimit;

cmpthese($count,{
  'rev primes'=> sub { $s=0; $s += $_ for reverse @{primes($nlimit)}; die unless $s == $expect; },
  'nthprime'  => sub { $s=0; $s += nth_prime($_) for reverse 1..$ilimit+1; die unless $s == $expect; },
  'pa index'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $primes[$_] for reverse 0..$ilimit;
                       die unless $s == $expect; },
  'tiedarray' => sub { $s=0; tie my @primes, "Math::Prime::TiedArray", extend_step => 1000;
                       $s += $primes[$_] for reverse 0..$ilimit;
                       die unless $s == $expect; },
});
}

if (1) {
print "Random walk in 1M\n";
srand(29);
my @rindex;
do { push @rindex, int(rand(1000000)) } for 1..10000;
$expect = 0; $expect += nth_prime($_+1) for @rindex;

cmpthese($count,{
  'nthprime'  => sub { $s=0; $s += nth_prime($_+1) for @rindex; },
  'pa index'  => sub { $s=0; tie my @primes, "Math::Prime::Util::PrimeArray";
                       $s += $primes[$_] for @rindex;
                       die unless $s == $expect; },
   # Argh!  Is it possible to write a slower sieve than the one MPTA uses?
  #'tiedarray' => sub { $s=0; tie my @primes, "Math::Prime::TiedArray", extend_step => 10000;
  #                     $s += $primes[$_] for @rindex;
  #                     die unless $s == $expect; },
});
}
