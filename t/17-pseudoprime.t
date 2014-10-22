#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Math::Prime::Util qw/is_prime miller_rabin/;

my $use64 = Math::Prime::Util::_maxbits > 32;
my $extra = defined $ENV{RELEASE_TESTING} && $ENV{RELEASE_TESTING};

plan tests => 3 + 4 + 295 + 4 + 4*$use64 + 1 + 1*$extra + 161;

ok(!eval { miller_rabin(2047); }, "MR with no base fails");
ok(!eval { miller_rabin(2047,0); }, "MR base 0 fails");
ok(!eval { miller_rabin(2047,1); }, "MR base 1 fails");

is( miller_rabin(0, 2), 0, "MR with 0 shortcut composite");
is( miller_rabin(1, 2), 0, "MR with 0 shortcut composite");
is( miller_rabin(2, 2), 2, "MR with 2 shortcut prime");
is( miller_rabin(3, 2), 2, "MR with 3 shortcut prime");

# small primes
my @sp = qw/2 3 5 7 11 13 17 19 23 29 31 37/;
# strong pseudoprimes for all prime bases 2 .. pn
my @phis = qw/2047 1373653 25326001 3215031751 2152302898747 3474749660383 341550071728321 341550071728321/;

# pseudoprimes from 2-100k for each prime base
# perl -E 'use Math::Primality ":all"; for (2 .. 100000) { print "$_ " if is_strong_pseudoprime($_,17) && !is_prime($_); } print "\n"'
my @psrp = (
  [ qw/2047 3277 4033 4681 8321 15841 29341 42799 49141 52633 65281 74665 80581 85489 88357 90751/ ],
  [ qw/121 703 1891 3281 8401 8911 10585 12403 16531 18721 19345 23521 31621 44287 47197 55969 63139 74593 79003 82513 87913 88573 97567/ ],
  [ qw/781 1541 5461 5611 7813 13021 14981 15751 24211 25351 29539 38081 40501 44801 53971 79381/ ],
  [ qw/25 325 703 2101 2353 4525 11041 14089 20197 29857 29891 39331 49241 58825 64681 76627 78937 79381 87673 88399 88831/ ],
  [ qw/133 793 2047 4577 5041 12403 13333 14521 17711 23377 43213 43739 47611 48283 49601 50737 50997 56057 58969 68137 74089 85879 86347 87913 88831/ ],
  [ qw/85 1099 5149 7107 8911 9637 13019 14491 17803 19757 20881 22177 23521 26521 35371 44173 45629 54097 56033 57205 75241 83333 85285 86347/ ],
  [ qw/9 91 145 781 1111 2821 4033 4187 5365 5833 6697 7171 15805 19729 21781 22791 24211 26245 31621 33001 33227 34441 35371 38081 42127 49771 71071 74665 77293 78881 88831 96433 97921 98671/ ],
  [ qw/9 49 169 343 1849 2353 2701 4033 4681 6541 6697 7957 9997 12403 13213 13747 15251 16531 18769 19729 24761 30589 31621 31861 32477 41003 49771 63139 64681 65161 66421 68257 73555 96049/ ],
  [ qw/169 265 553 1271 2701 4033 4371 4681 6533 6541 7957 8321 8651 8911 9805 14981 18721 25201 31861 34133 44173 47611 47783 50737 57401 62849 82513 96049/ ],
  [ qw/15 91 341 469 871 2257 4371 4411 5149 6097 8401 11581 12431 15577 16471 19093 25681 28009 29539 31417 33001 48133 49141 54913 79003/ ],
  [ qw/15 49 133 481 931 6241 8911 9131 10963 11041 14191 17767 29341 56033 58969 68251 79003 83333 87061 88183/ ],
  [ qw/9 451 469 589 685 817 1333 3781 8905 9271 18631 19517 20591 25327 34237 45551 46981 47587 48133 59563 61337 68101 68251 73633 79381 79501 83333 84151 96727/ ],
);

# Check that each strong pseudoprime base b makes it through MR with that base
my $bindex = 0;
foreach my $base (@sp) {
  foreach my $p ( @{ $psrp[$bindex++] } ) {
    ok(miller_rabin($p, $base), "Pseudoprime (base $base) $p passes MR");
  }
}

# Check that phi_n makes passes MR with all prime bases < pn
for my $phi (1 .. 8) {
  next if ($phi > 4) && (!$use64);
  ok( miller_rabin($phis[$phi-1], @sp[0 .. $phi-1]), "phi_$phi passes MR with first $phi primes");
}

# Verify MR base 2 for all small numbers
{
  my $mr2fail = 0;
  for (2 .. 4032) {
    next if $_ == 2047 || $_ == 3277;
    if (is_prime($_)) {
      if (!miller_rabin($_,2)) { $mr2fail = $_; last; }
    } else {
      if (miller_rabin($_,2))  { $mr2fail = $_; last; }
    }
  }
  is($mr2fail, 0, "miller_rabin base 2 matches is_prime for 2-2046,2048-3276,3278-4032");
}

# Verify MR base 2-3 for many small numbers (up to phi2)
if ($extra) {
  my $mr2fail = 0;
  for (2 .. 1373652) {
    if (is_prime($_)) {
      if (!miller_rabin($_,2,3)) { $mr2fail = $_; last; }
    } else {
      if (miller_rabin($_,2,3))  { $mr2fail = $_; last; }
    }
  }
  is($mr2fail, 0, "miller_rabin bases 2,3 matches is_prime to 1,373,652");
}

# More bases
my @ebases = qw/61 73 325 9375 28178 75088 450775 642735/;
my @epsrp = (
  [ qw/217 341 1261 2701 3661 6541 6697 7613 13213 16213 22177 23653 23959 31417 50117 61777 63139 67721 76301 77421 79381 80041/ ],
  [ qw/205 259 533 1441 1921 2665 3439 5257 15457 23281 24617 26797 27787 28939 34219 39481 44671 45629 64681 67069 76429 79501 93521/ ],
  [ qw/341 343 697 1141 2059 2149 3097 3537 4033 4681 4941 5833 6517 7987 8911 12403 12913 15043 16021 20017 22261 23221 24649 24929 31841 35371 38503 43213 44173 47197 50041 55909 56033 58969 59089 61337 65441 68823 72641 76793 78409 85879/ ],
  [ qw/11521 14689 17893 18361 20591 28093 32809 37969 44287 60701 70801 79957 88357 88831 94249 96247 99547/ ],
  [ qw/28179 29381 30353 34441 35371 37051 38503 43387 50557 51491 57553 79003 82801 83333 87249 88507 97921 99811/ ],
  [ qw/75089 79381 81317 91001 100101 111361 114211 136927 148289 169641 176661 191407 195649/ ],
  [ qw/465991 468931 485357 505441 536851 556421 578771 585631 586249 606361 631651 638731 641683 645679/ ],
  [ qw/653251 653333 663181 676651 714653 759277 794683 805141 844097 872191 874171 894671/ ],
);

# Check some of the extra bases we use
$bindex = 0;
foreach my $base (@ebases) {
  foreach my $p ( @{ $epsrp[$bindex++] } ) {
    ok(miller_rabin($p, $base), "Pseudoprime (base $base) $p passes MR");
  }
}
# TODO:
#  add tests for bases:
#                      1005905886, 1340600841, 553174392, 3046413974,
#                      203659041, 3613982119,
#                      9780504, 1795265022
