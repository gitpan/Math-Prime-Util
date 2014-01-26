#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Math::Prime::Util qw/primes prime_count/;

my $use64 = Math::Prime::Util::prime_get_config->{'maxbits'} > 32;
$use64 = 0 if 18446744073709550592 == ~0;
my $usexs = Math::Prime::Util::prime_get_config->{'xs'};

my %primesubs = (
  trial   => \&Math::Prime::Util::trial_primes,
  erat    => \&Math::Prime::Util::erat_primes,
  segment => \&Math::Prime::Util::segment_primes,
  sieve   => \&Math::Prime::Util::sieve_primes,
  primes  => \&Math::Prime::Util::primes,
);
# Don't test the private XS methods if we're not using XS.
delete @primesubs{qw/trial erat segment sieve/} unless $usexs;

plan tests => 12+3 + 12 + 1 + 19 + ($use64 ? 1 : 0) + 1 + 13*scalar(keys(%primesubs));

ok(!eval { primes(undef); },   "primes(undef)");
ok(!eval { primes("a"); },     "primes(a)");
ok(!eval { primes(-4); },      "primes(-4)");
ok(!eval { primes(2,undef); }, "primes(2,undef)");
ok(!eval { primes(2,'x'); },   "primes(2,x)");
ok(!eval { primes(2,-4); },    "primes(2,-4)");
ok(!eval { primes(undef,7); }, "primes(undef,7)");
ok(!eval { primes('x',7); },   "primes(x,7)");
ok(!eval { primes(-10,7); },   "primes(-10,7)");
ok(!eval { primes(undef,undef); },  "primes(undef,undef)");
ok(!eval { primes('x','x'); }, "primes(x,x)");
ok(!eval { primes(-10,-4); },  "primes(-10,-4)");

ok(!eval { primes(50000000000000000000); },  "primes(inf)");
ok(!eval { primes(2,50000000000000000000); },  "primes(2,inf)");
ok(!eval { primes(50000000000000000000,50000000000000000001); },  "primes(inf,inf)");

my @small_primes = qw/
2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71
73 79 83 89 97 101 103 107 109 113 127 131 137 139 149 151 157 163 167 173
179 181 191 193 197 199 211 223 227 229 233 239 241 251 257 263 269 271 277 281
283 293 307 311 313 317 331 337 347 349 353 359 367 373 379 383 389 397 401 409
419 421 431 433 439 443 449 457 461 463 467 479 487 491 499 503 509 521 523 541
547 557 563 569 571 577 587 593 599 601 607 613 617 619 631 641 643 647 653 659
661 673 677 683 691 701 709 719 727 733 739 743 751 757 761 769 773 787 797 809
811 821 823 827 829 839 853 857 859 863 877 881 883 887 907 911 919 929 937 941
947 953 967 971 977 983 991 997 1009 1013 1019 1021 1031 1033 1039 1049 1051 1061 1063 1069
1087 1091 1093 1097 1103 1109 1117 1123 1129 1151 1153 1163 1171 1181 1187 1193 1201 1213 1217 1223
1229 1231 1237 1249 1259 1277 1279 1283 1289 1291 1297 1301 1303 1307 1319 1321 1327 1361 1367 1373
1381 1399 1409 1423 1427 1429 1433 1439 1447 1451 1453 1459 1471 1481 1483 1487 1489 1493 1499 1511
1523 1531 1543 1549 1553 1559 1567 1571 1579 1583 1597 1601 1607 1609 1613 1619 1621 1627 1637 1657
1663 1667 1669 1693 1697 1699 1709 1721 1723 1733 1741 1747 1753 1759 1777 1783 1787 1789 1801 1811
1823 1831 1847 1861 1867 1871 1873 1877 1879 1889 1901 1907 1913 1931 1933 1949 1951 1973 1979 1987
1993 1997 1999 2003 2011 2017 2027 2029 2039 2053 2063 2069 2081 2083 2087 2089 2099 2111 2113 2129
2131 2137 2141 2143 2153 2161 2179 2203 2207 2213 2221 2237 2239 2243 2251 2267 2269 2273 2281 2287
2293 2297 2309 2311 2333 2339 2341 2347 2351 2357 2371 2377 2381 2383 2389 2393 2399 2411 2417 2423
2437 2441 2447 2459 2467 2473 2477 2503 2521 2531 2539 2543 2549 2551 2557 2579 2591 2593 2609 2617
2621 2633 2647 2657 2659 2663 2671 2677 2683 2687 2689 2693 2699 2707 2711 2713 2719 2729 2731 2741
2749 2753 2767 2777 2789 2791 2797 2801 2803 2819 2833 2837 2843 2851 2857 2861 2879 2887 2897 2903
2909 2917 2927 2939 2953 2957 2963 2969 2971 2999 3001 3011 3019 3023 3037 3041 3049 3061 3067 3079
3083 3089 3109 3119 3121 3137 3163 3167 3169 3181 3187 3191 3203 3209 3217 3221 3229 3251 3253 3257
3259 3271 3299 3301 3307 3313 3319 3323 3329 3331 3343 3347 3359 3361 3371 3373 3389 3391 3407 3413
3433 3449 3457 3461 3463 3467 3469 3491 3499 3511 3517 3527 3529 3533 3539 3541 3547 3557 3559 3571
/;

my %small_single = (
    0   => [],
    1   => [],
    2   => [2],
    3   => [2, 3],
    4   => [2, 3],
    5   => [2, 3, 5],
    6   => [2, 3, 5],
    7   => [2, 3, 5, 7],
    11  => [2, 3, 5, 7, 11],
    18  => [2, 3, 5, 7, 11, 13, 17],
    19  => [2, 3, 5, 7, 11, 13, 17, 19],
    20  => [2, 3, 5, 7, 11, 13, 17, 19],
);

while (my($high, $expect) = each (%small_single)) {
  is_deeply( primes($high), $expect, "primes($high) should return [@{$expect}]");
}

is_deeply( primes(0, 3572), \@small_primes, "Primes between 0 and 3572" );

my %small_range = (
  "3 to 9" => [3,5,7],
  "2 to 20" => [2,3,5,7,11,13,17,19],
  "30 to 70" => [31,37,41,43,47,53,59,61,67],
  "70 to 30" => [],
  "20 to 2" => [],
  "2 to 2" => [2],
  "3 to 3" => [3],
  "2 to 3" => [2,3],
  "2 to 5" => [2,3,5],
  "3 to 6" => [3,5],
  "3 to 7" => [3,5,7],
  "4 to 8" => [5,7],
  "2010733 to 2010881" => [2010733,2010881],
  "2010734 to 2010880" => [],
  "3088 to 3164" => [3089,3109,3119,3121,3137,3163],
  "3089 to 3163" => [3089,3109,3119,3121,3137,3163],
  "3090 to 3162" => [3109,3119,3121,3137],
  "3842610773 to 3842611109" => [3842610773,3842611109],
  "3842610774 to 3842611108" => [],
);

while (my($range, $expect) = each (%small_range)) {
  my($low,$high) = $range =~ /(\d+) to (\d+)/;
  is_deeply( primes($low, $high), $expect, "primes($low,$high) should return [@{$expect}]");
}

if ($use64) {
  is_deeply( primes(1_693_182_318_746_371, 1_693_182_318_747_671),
             [qw/1693182318746371 1693182318747503 1693182318747523
                 1693182318747553 1693182318747583 1693182318747613
                 1693182318747631 1693182318747637/], "Primes between 1_693_182_318_746_371 and 1_693_182_318_747_671");
}

is( scalar @{primes(474973,838390)}, prime_count(838390) - prime_count(474973), "count primes within a range" );

# Test individual methods
while (my($method, $sub) = each (%primesubs)) {
  is_deeply( $sub->(0, 3572), \@small_primes, "$method(0, 3572)" );
  is_deeply( $sub->(2, 20), [2,3,5,7,11,13,17,19], "$method(2, 20)" );
  is_deeply( $sub->(30, 70), [31,37,41,43,47,53,59,61,67], "$method(30, 70)" );
  is_deeply( $sub->(30, 70), [31,37,41,43,47,53,59,61,67], "$method(30, 70)" );
  is_deeply( $sub->(20, 2), [], "$method(20, 2)" );
  is_deeply( $sub->(1, 1), [], "$method(1, 1)" );
  is_deeply( $sub->(2, 2), [2], "$method(2, 2)" );
  is_deeply( $sub->(3, 3), [3], "$method(3, 3)" );
  is_deeply( $sub->(2010733, 2010733+148), [2010733,2010733+148], "$method Primegap 21 inclusive" );
  is_deeply( $sub->(2010733+1, 2010733+148-2), [], "$method Primegap 21 exclusive" );
  is_deeply( $sub->(3088, 3164), [3089,3109,3119,3121,3137,3163], "$method(3088, 3164)" );
  is_deeply( $sub->(3089, 3163), [3089,3109,3119,3121,3137,3163], "$method(3089, 3163)" );
  is_deeply( $sub->(3090, 3162), [3109,3119,3121,3137], "$method(3090, 3162)" );
}
