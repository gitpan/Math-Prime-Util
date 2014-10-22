package Math::Prime::Util::PP;
use strict;
use warnings;
use Carp qw/carp croak confess/;

BEGIN {
  $Math::Prime::Util::PP::AUTHORITY = 'cpan:DANAJ';
  $Math::Prime::Util::PP::VERSION = '0.09';
}

# The Pure Perl versions of all the Math::Prime::Util routines.
#
# Some of these will be relatively similar in performance, some will be
# very slow in comparison.
#
# Most of these are pretty simple.  Also, you really should look at the C
# code for more detailed comments, including references to papers.

my $_uv_size;
BEGIN {
  use Config;
  $_uv_size =
   (   (defined $Config{'use64bitint'} && $Config{'use64bitint'} eq 'define')
    || (defined $Config{'use64bitall'} && $Config{'use64bitall'} eq 'define')
    || (defined $Config{'longsize'} && $Config{'longsize'} >= 8)
   )
   ? 64
   : 32;
  no Config;
}
sub _maxbits { $_uv_size }

my $_precalc_size = 0;
sub prime_precalc {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  $_precalc_size = $n if $n > $_precalc_size;
}
sub prime_memfree {
  $_precalc_size = 0;
}
sub _get_prime_cache_size { $_precalc_size }
sub _prime_memfreeall { prime_memfree; }


sub _is_positive_int {
  ((defined $_[0]) && ($_[0] !~ tr/0123456789//c));
}

my @_primes_small = (
   0,2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97,
   101,103,107,109,113,127,131,137,139,149,151,157,163,167,173,179,181,191,
   193,197,199,211,223,227,229,233,239,241,251,257,263,269,271,277,281,283,
   293,307,311,313,317,331,337,347,349,353,359,367,373,379,383,389,397,401,
   409,419,421,431,433,439,443,449,457,461,463,467,479,487,491,499);
my @_prime_count_small = (
   0,0,1,2,2,3,3,4,4,4,4,5,5,6,6,6,6,7,7,8,8,8,8,9,9,9,9,9,9,10,10,
   11,11,11,11,11,11,12,12,12,12,13,13,14,14,14,14,15,15,15,15,15,15,
   16,16,16,16,16,16,17,17,18,18,18,18,18,18,19);
my @_prime_next_small = (
   2,2,3,5,5,7,7,11,11,11,11,13,13,17,17,17,17,19,19,23,23,23,23,
   29,29,29,29,29,29,31,31,37,37,37,37,37,37,41,41,41,41,43,43,47,
   47,47,47,53,53,53,53,53,53,59,59,59,59,59,59,61,61,67,67,67,67,67,67,71);

# For wheel-30
my @_prime_indices = (1, 7, 11, 13, 17, 19, 23, 29);
my @_nextwheel30 = (1,7,7,7,7,7,7,11,11,11,11,13,13,17,17,17,17,19,19,23,23,23,23,29,29,29,29,29,29,1);
my @_prevwheel30 = (29,29,1,1,1,1,1,1,7,7,7,7,11,11,13,13,13,13,17,17,19,19,19,19,23,23,23,23,23,23);

sub _is_prime7 {  # n must not be divisible by 2, 3, or 5
  my($x) = @_;
  my $q;
  foreach my $i (qw/7 11 13 17 19 23 29 31 37 41 43 47 53 59/) {
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);
  }

  return is_prob_prime($x) if $x > 10_000_000;

  my $i = 61;  # mod-30 loop
  while (1) {
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 6;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 4;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 2;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 4;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 2;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 4;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 6;
    $q = int($x/$i); return 2 if $q < $i; return 0 if $x == ($q*$i);  $i += 2;
  }
  2;
}

sub is_prime {
  my($n) = @_;
  croak "Input must be an integer" unless defined $_[0];
  return 0 if $n < 2;        # 0 and 1 are composite
  return 2 if ($n == 2) || ($n == 3) || ($n == 5);  # 2, 3, 5 are prime
  # multiples of 2,3,5 are composite
  return 0 if (($n % 2) == 0) || (($n % 3) == 0) || (($n % 5) == 0);

  return _is_prime7($n);
}

# Possible sieve storage:
#   1) vec with mod-30 wheel:   8 bits  / 30
#   2) vec with mod-2 wheel :  15 bits  / 30
#   3) str with mod-30 wheel:   8 bytes / 30
#   4) str with mod-2 wheel :  15 bytes / 30
#
# It looks like using vecs is about 2x slower than strs, and the strings also
# let us do some fast operations on the results.  E.g.
#   Count all primes:
#      $count += $$sieveref =~ tr/0//;
#   Loop over primes:
#      foreach my $s (split("0", $$sieveref, -1)) {
#        $n += 2 + 2 * length($s);
#        .. do something with the prime $n
#      }
#
# We're using method 4, though sadly it is memory intensive.
#
# Even so, it is a lot less memory than making an array entry for each number,
# and the performance is almost 10x faster than a naive array sieve.

sub _sieve_erat_string {
  my($end) = @_;

  # Prefill with 3 and 5 already marked.
  my $whole = int( ($end>>1) / 15);
  my $sieve = "100010010010110" . "011010010010110" x $whole;
  # Make exactly the number of entries requested, never more.
  substr($sieve, ($end>>1)+1) = '';
  my $n = 7;
  while ( ($n*$n) <= $end ) {
    my $s = $n*$n;
    my $filter_s   = $s >> 1;
    my $filter_end = $end >> 1;
    while ($filter_s <= $filter_end) {
      substr($sieve, $filter_s, 1) = "1";
      $filter_s += $n;
    }
    do { $n += 2 } while substr($sieve, $n>>1, 1);
  }
  \$sieve;
}

# TODO: this should be plugged into precalc, memfree, etc. just like the C code
{
  my $primary_size_limit = 15000;
  my $primary_sieve_size = 0;
  my $primary_sieve_ref;
  sub _sieve_erat {
    my($end) = @_;

    return _sieve_erat_string($end) if $end > $primary_size_limit;

    if ($primary_sieve_size == 0) {
      $primary_sieve_size = $primary_size_limit;
      $primary_sieve_ref = _sieve_erat_string($primary_sieve_size);
    }
    my $sieve = substr($$primary_sieve_ref, 0, ($end+1)>>1);
    \$sieve;
  }
}


sub _sieve_segment {
  my($beg,$end) = @_;
  croak "Internal error: segment beg is even" if ($beg % 2) == 0;
  croak "Internal error: segment end is even" if ($end % 2) == 0;
  croak "Internal error: segment end < beg" if $end < $beg;
  croak "Internal error: segment beg should be >= 3" if $beg < 3;
  my $range = int( ($end - $beg) / 2 ) + 1;

  # Prefill with 3 and 5 already marked, and offset to the segment start.
  my $whole = int( ($range+14) / 15);
  my $startp = ($beg % 30) >> 1;
  my $sieve = substr("011010010010110", $startp) . "011010010010110" x $whole;
  # Set 3 and 5 to prime if we're sieving them.
  substr($sieve,0,2) = "00" if $beg == 3;
  substr($sieve,0,1) = "0"  if $beg == 5;
  # Get rid of any extra we added.
  substr($sieve, $range) = '';

  # If the end value is below 7^2, then the pre-sieve is all we needed.
  return \$sieve if $end < 49;

  my $limit = int(sqrt($end)) + 1;
  # For large value of end, it's a huge win to just walk primes.
  my $primesieveref = _sieve_erat($limit);
  my $p = 7-2;
  foreach my $s (split("0", substr($$primesieveref, 3), -1)) {
    $p += 2 + 2 * length($s);
    my $p2 = $p*$p;
    last if $p2 > $end;
    if ($p2 < $beg) {
      $p2 = int($beg / $p) * $p;
      $p2 += $p if $p2 < $beg;
      $p2 += $p if ($p2 % 2) == 0;   # Make sure p2 is odd
    }
    # With large bases and small segments, it's common to find we don't hit
    # the segment at all.  Skip all the setup if we find this now.
    if ($p2 <= $end) {
      # Inner loop marking multiples of p
      # (everything is divided by 2 to keep inner loop simpler)
      my $filter_end = ($end - $beg) >> 1;
      my $filter_p2  = ($p2  - $beg) >> 1;
      while ($filter_p2 <= $filter_end) {
        substr($sieve, $filter_p2, 1) = "1";
        $filter_p2 += $p;
      }
    }
  }
  \$sieve;
}

sub primes {
  my $optref = (ref $_[0] eq 'HASH')  ?  shift  :  {};
  croak "no parameters to primes" unless scalar @_ > 0;
  croak "too many parameters to primes" unless scalar @_ <= 2;
  my $low = (@_ == 2)  ?  shift  :  2;
  my $high = shift;
  my $sref = [];

  croak "Input must be a positive integer" unless _is_positive_int($low)
                                               && _is_positive_int($high);

  return $sref if ($low > $high) || ($high < 2);

  # Ignore method options in this code

  push @$sref, 2  if ($low <= 2) && ($high >= 2);
  push @$sref, 3  if ($low <= 3) && ($high >= 3);
  push @$sref, 5  if ($low <= 5) && ($high >= 5);
  $low = 7 if $low < 7;
  $low++ if ($low % 2) == 0;
  $high-- if ($high % 2) == 0;
  return $sref if $low > $high;

  if ($low == 7) {
    my $sieveref = _sieve_erat($high);
    my $n = $low - 2;
    foreach my $s (split("0", substr($$sieveref, 3), -1)) {
      $n += 2 + 2 * length($s);
      push @$sref, $n if $n <= $high;
    }
  } else {
    my $sieveref = _sieve_segment($low,$high);
    my $n = $low - 2;
    foreach my $s (split("0", $$sieveref, -1)) {
      $n += 2 + 2 * length($s);
      push @$sref, $n if $n <= $high;
    }
  }
  $sref;
}

sub next_prime {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  return 0 if $n >= ((_maxbits == 32) ? 4294967291 : 18446744073709551557);
  return $_prime_next_small[$n] if $n <= $#_prime_next_small;

  my $d = int($n/30);
  my $m = $n - $d*30;
  if ($m == 29) { $d++;  $m = 1;} else { $m = $_nextwheel30[$m]; }
  while (!_is_prime7($d*30+$m)) {
    $m = $_nextwheel30[$m];
    $d++ if $m == 1;
  }
  $d*30 + $m;
}

sub prev_prime {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  if ($n <= 7) {
    return ($n <= 2) ? 0 : ($n <= 3) ? 2 : ($n <= 5) ? 3 : 5;
  }

  $n++ if ($n % 2) == 0;
  do {
    $n -= 2;
  } while ( (($n % 3) == 0) || (!is_prime($n)) );
  $n;

  # This is faster for larger intervals, slower for short ones.
  #my $base = 30 * int($n/30);
  #my $in = 0;  $in++ while ($n - $base) > $_prime_indices[$in];
  #if (--$in < 0) {  $base -= 30; $in = 7;  }
  #$n = $base + $_prime_indices[$in];
  #while (!_is_prime7($n)) {
  #  if (--$in < 0) {  $base -= 30; $in = 7;  }
  #  $n = $base + $_prime_indices[$in];
  #}
  #$n;

  #my $d = int($n/30);
  #my $m = $n - $d*30;
  #do {
  #  $m = $_prevwheel30[$m];
  #  $d-- if $m == 29;
  #} while (!_is_prime7($d*30+$m));
  #$d*30+$m;
}

sub prime_count {
  my($low,$high) = @_;
  if (!defined $high) {
    $high = $low;
    $low = 2;
  }
  croak "Input must be a positive integer" unless _is_positive_int($low)
                                               && _is_positive_int($high);

  my $count = 0;

  $count++ if ($low <= 2) && ($high >= 2);   # Count 2
  $low = 3 if $low < 3;

  $low++ if ($low % 2) == 0;   # Make low go to odd number.
  $high-- if ($high % 2) == 0; # Make high go to odd number.
  return $count if $low > $high;

  my $sieveref;

  if ($low == 3) {
    $sieveref = _sieve_erat($high);
  } else {
    $sieveref = _sieve_segment($low,$high);
  }

  $count += $$sieveref =~ tr/0//;

  $count;
}

sub prime_count_lower {
  my($x) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  my $flogx = log($x);

  return int( $x / ($flogx - 0.7) ) if $x < 599;

  my $a;
  if    ($x <       2700) { $a = 0.30; }
  elsif ($x <       5500) { $a = 0.90; }
  elsif ($x <      19400) { $a = 1.30; }
  elsif ($x <      32299) { $a = 1.60; }
  elsif ($x <     176000) { $a = 1.80; }
  elsif ($x <     315000) { $a = 2.10; }
  elsif ($x <    1100000) { $a = 2.20; }
  elsif ($x <    4500000) { $a = 2.31; }
  elsif ($x <  233000000) { $a = 2.36; }
  elsif ($x < 5433800000) { $a = 2.32; }
  elsif ($x <60000000000) { $a = 2.15; }
  else                    { $a = 1.80; } # Dusart 1999, page 14

  return int( ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) );
}

sub prime_count_upper {
  my($x) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  my $flogx = log($x);

  return int( ($x / ($flogx - 1.048)) + 1.0 ) if $x <  1621;
  return int( ($x / ($flogx - 1.071)) + 1.0 ) if $x <  5000;
  return int( ($x / ($flogx - 1.098)) + 1.0 ) if $x < 15900;

  my $a;
  if    ($x <      24000) { $a = 2.30; }
  elsif ($x <      59000) { $a = 2.48; }
  elsif ($x <     350000) { $a = 2.52; }
  elsif ($x <     355991) { $a = 2.54; }
  elsif ($x <     356000) { $a = 2.51; }
  elsif ($x <    3550000) { $a = 2.50; }
  elsif ($x <    3560000) { $a = 2.49; }
  elsif ($x <    5000000) { $a = 2.48; }
  elsif ($x <    8000000) { $a = 2.47; }
  elsif ($x <   13000000) { $a = 2.46; }
  elsif ($x <   18000000) { $a = 2.45; }
  elsif ($x <   31000000) { $a = 2.44; }
  elsif ($x <   41000000) { $a = 2.43; }
  elsif ($x <   48000000) { $a = 2.42; }
  elsif ($x <  119000000) { $a = 2.41; }
  elsif ($x <  182000000) { $a = 2.40; }
  elsif ($x <  192000000) { $a = 2.395; }
  elsif ($x <  213000000) { $a = 2.390; }
  elsif ($x <  271000000) { $a = 2.385; }
  elsif ($x <  322000000) { $a = 2.380; }
  elsif ($x <  400000000) { $a = 2.375; }
  elsif ($x <  510000000) { $a = 2.370; }
  elsif ($x <  682000000) { $a = 2.367; }
  elsif ($x <60000000000) { $a = 2.362; }
  else                    { $a = 2.51; }

  return int( ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) + 1.0 );
}

sub prime_count_approx {
  my($x) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  #return int( (prime_count_upper($x) + prime_count_lower($x)) / 2);
  return int(RiemannR($x)+0.5);
}

sub nth_prime_lower {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  my $flogn  = log($n);
  my $flog2n = log($flogn);

  # Dusart 1999 page 14, for all n >= 2
  my $lower = $n * ($flogn + $flog2n - 1.0 + (($flog2n-2.25)/$flogn));

  if ($lower >= ~0) {
    if (_maxbits == 32) {
      return 4294967291 if $n <= 203280221;
    } else {
      return 18446744073709551557 if $n <= 425656284035217743;
    }
    croak "nth_prime_lower($n) overflow";
  }
  return int($lower);
}

sub nth_prime_upper {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  my $flogn  = log($n);
  my $flog2n = log($flogn);

  my $upper;
  if ($n >= 39017) {
    $upper = $n * ( $flogn  +  $flog2n - 0.9484 ); # Dusart 1999 page 14
  } elsif ($n >= 27076) {
    $upper = $n * ( $flogn  +  $flog2n - 1.0 + (($flog2n-1.80)/$flogn) );
  } elsif ($n >= 7022) {
    $upper = $n * ( $flogn  +  0.9385 * $flog2n ); # Robin 1983
  } else {
    $upper = $n * ( $flogn  +  $flog2n );
  }

  if ($upper >= ~0) {
    if (_maxbits == 32) {
      return 4294967291 if $n <= 203280221;
    } else {
      return 18446744073709551557 if $n <= 425656284035217743;
    }
    croak "nth_prime_upper($n) overflow";
  }
  return int($upper + 1.0);
}

sub nth_prime_approx {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  my $flogn  = log($n);
  my $flog2n = log($flogn);

  my $approx = $n * ( $flogn + $flog2n - 1
                      + (($flog2n - 2)/$flogn)
                      - ((($flog2n*$flog2n) - 6*$flog2n + 11) / (2*$flogn*$flogn))
                    );

  my $order = $flog2n/$flogn;
  $order = $order*$order*$order * $n;

  if    ($n <        259) { $approx += 10.4 * $order; }
  elsif ($n <        775) { $approx +=  7.52* $order; }
  elsif ($n <       1271) { $approx +=  5.6 * $order; }
  elsif ($n <       2000) { $approx +=  5.2 * $order; }
  elsif ($n <       4000) { $approx +=  4.3 * $order; }
  elsif ($n <      12000) { $approx +=  3.0 * $order; }
  elsif ($n <     150000) { $approx +=  2.1 * $order; }
  elsif ($n <  200000000) { $approx +=  0.0 * $order; }
  else                    { $approx += -0.010 * $order; }

  if ($approx >= ~0) {
    if (_maxbits == 32) {
      return 4294967291 if $n <= 203280221;
    } else {
      return 18446744073709551557 if $n <= 425656284035217743;
    }
    croak "nth_prime_approx($n) overflow";
  }

  return int($approx + 0.5);
}

sub nth_prime {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  if (_maxbits == 32) {
    croak "nth_prime($n) overflow" if $n > 203280221;
  } else {
    croak "nth_prime($n) overflow" if $n > 425656284035217743;
  }

  my $prime = 0;

  {
    my $count = 1;
    my $start = 3;
    # Make sure incr is an even number.
    my $incr = ($n < 1000) ? 1000 : ($n < 10000) ? 10000 : 100000;
    my $sieveref;
    while (1) {
      $sieveref = _sieve_segment($start, $start+$incr);
      my $segcount = $$sieveref =~ tr/0//;
      last if ($count + $segcount) >= $n;
      $count += $segcount;
      $start += $incr+2;
    }
    # Our count is somewhere in this segment.  Need to look for it.
    $prime = $start - 2;
    while ($count < $n) {
      $prime += 2;
      $count++ if !substr($$sieveref, ($prime-$start)>>1, 1);
    }
  }
  $prime;
}

sub _mulmod {
  my($a, $b, $m) = @_;
  my $r = 0;
  while ($b > 0) {
    if ($b & 1) {
      if ($r == 0) {
        $r = $a;
      } else {
        $r = $m - $r;
        $r = ($a >= $r)  ?  $a - $r  :  $m - $r + $a;
      }
    }
    $a = ($a > ($m - $a))  ?  ($a - $m) + $a  :  $a + $a;
    $b >>= 1;
  }
  $r;
}

sub _powmod {
  my($n, $power, $m) = @_;
  my $t = 1;

  if ( (~0 == 18446744073709551615) && ($m < 4294967296) ) {
    $n %= $m;
    while ($power) {
      $t = ($t * $n) % $m if ($power & 1) != 0;
      $n = ($n * $n) % $m;
      $power >>= 1;
    }
  } else {
    while ($power) {
      $t = _mulmod($t, $n, $m) if ($power & 1) != 0;
      $n = _mulmod($n, $n, $m);
      $power >>= 1;
    }
  }
  $t;
}

sub _gcd_ui {
  my($x, $y) = @_;
  if ($y < $x) { ($x, $y) = ($y, $x); }
  while ($y > 0) {
    # y1 <- x0 % y0 ; x1 <- y0
    my $t = $y;
    $y = $x % $y;
    $x = $t;
  }
  $x;
}


sub miller_rabin {
  my($n, @bases) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  croak "No bases given to miller_rabin" unless @bases;

  return 0 if ($n == 0) || ($n == 1);
  return 2 if ($n == 2) || ($n == 3);

  # I was using bignum here for a while, but doing "$a ** $d" with a
  # big $d is **ridiculously** slow.  It's thousands of times faster
  # to do it ourselves using _powmod and _mulmod.

  my $s = 0;
  my $d = $n - 1;

  while ( ($d & 1) == 0 ) {
    $s++;
    $d >>= 1;
  }

  foreach my $a (@bases) {
    croak "Base $a is invalid" if $a < 2;
    my $x = _powmod($a, $d, $n);
    next if ($x == 1) || ($x == ($n-1));

    if (~0 == 18446744073709551615) {
      foreach my $r (1 .. $s) {
        $x = ($x < 4294967296) ? ($x*$x) % $n : _mulmod($x, $x, $n);
        return 0 if $x == 1;
        if ($x == ($n-1)) {
          $a = 0;
          last;
        }
      }
    } else {
      foreach my $r (1 .. $s) {
        $x = ($x < 65536) ? ($x*$x) % $n : _mulmod($x, $x, $n);
        return 0 if $x == 1;
        if ($x == ($n-1)) {
          $a = 0;
          last;
        }
      }
    }
    return 0 if $a != 0;
  }
  1;
}

sub is_prob_prime {
  my($n) = @_;

  return 2 if ($n == 2) || ($n == 3) || ($n == 5) || ($n == 7);
  return 0 if ($n < 2) || (($n % 2) == 0) || (($n % 3) == 0) || (($n % 5) == 0) || (($n % 7) == 0);
  return 2 if $n < 121;

  my @bases;
  if    ($n <          9080191) { @bases = (31, 73); }
  elsif ($n <       4759123141) { @bases = (2, 7, 61); }
  elsif ($n <     105936894253) { @bases = (2, 1005905886, 1340600841); }
  elsif ($n <   31858317218647) { @bases = (2, 642735, 553174392, 3046413974); }
  elsif ($n < 3071837692357849) { @bases = (2, 75088, 642735, 203659041, 3613982119); }
  else                          { @bases = (2, 325, 9375, 28178, 450775, 9780504, 1795265022); }

  # Run our selected set of Miller-Rabin strong probability tests
  my $prob_prime = miller_rabin($n, @bases);
  # We're deterministic for 64-bit numbers
  $prob_prime *= 2 if $n <= ~0;
  $prob_prime;
}

sub _basic_factor {
  # MODIFIES INPUT SCALAR
  return ($_[0]) if $_[0] < 4;
  my @factors;
  while ( ($_[0] % 2) == 0 ) { push @factors, 2;  $_[0] /= 2; }
  while ( ($_[0] % 3) == 0 ) { push @factors, 3;  $_[0] /= 3; }
  while ( ($_[0] % 5) == 0 ) { push @factors, 5;  $_[0] /= 5; }
  if (is_prime($_[0])) {
    push @factors, $_[0];
    $_[0] = 1;
  }
  @factors;
}

sub trial_factor {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  my $limit = int( sqrt($n) + 0.001);
  my $f = 3;
  while ($f <= $limit) {
    if ( ($n % $f) == 0) {
      while ( ($n % $f) == 0) {
        push @factors, $f;
        $n /= $f;
      }
      $limit = int( sqrt($n) + 0.001);
    }
    $f += 2;
  }
  push @factors, $n  if $n > 1;
  @factors;
}

sub factor {
  my($n) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);

  return trial_factor($n) if $n < 100000;

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  while (($n %  7) == 0) { push @factors,  7;  $n /=  7; }
  while (($n % 11) == 0) { push @factors, 11;  $n /= 11; }
  while (($n % 13) == 0) { push @factors, 13;  $n /= 13; }
  while (($n % 17) == 0) { push @factors, 17;  $n /= 17; }
  while (($n % 19) == 0) { push @factors, 19;  $n /= 19; }
  while (($n % 23) == 0) { push @factors, 23;  $n /= 23; }
  while (($n % 29) == 0) { push @factors, 29;  $n /= 29; }

  my @nstack = ($n);
  while (@nstack) {
    $n = pop @nstack;
    #print "Looking at $n with stack ", join(",",@nstack), "\n";
    while ( ($n >= (31*31)) && !is_prime($n) ) {
      my @ftry;
      @ftry = prho_factor($n, 64*1024);
      @ftry = holf_factor($n, 64*1024)  if scalar @ftry == 1;
      if (scalar @ftry > 1) {
        #print "  split into ", join(",",@ftry), "\n";
        $n = shift @ftry;
        push @nstack, @ftry;
      } else {
        push @factors, trial_factor($n);
        #print "  trial into ", join(",",@factors), "\n";
        $n = 1;
        last;
      }
    }
    push @factors, $n  if $n != 1;
  }
  @factors;
}

# TODO:
sub fermat_factor { trial_factor(@_) }
sub squfof_factor { trial_factor(@_) }

sub prho_factor {
  my($n, $rounds) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  $rounds = 4*1024*1024 unless defined $rounds;

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  my $inloop = 0;
  my $a = 3;
  my $U = 7;
  my $V = 7;

  for my $i (1 .. $rounds) {
    # U^2+a % n
    $U = _mulmod($U, $U, $n);
    $U = (($n-$U) > $a)  ?  $U+$a  :  $U+$a-$n;
    # V^2+a % n
    $V = _mulmod($V, $V, $n);
    $V = (($n-$V) > $a)  ?  $V+$a  :  $V+$a-$n;
    # V^2+a % n
    $V = _mulmod($V, $V, $n);
    $V = (($n-$V) > $a)  ?  $V+$a  :  $V+$a-$n;
    my $f = _gcd_ui( ($U > $V) ? $U-$V : $V-$U,  $n );
    if ($f == $n) {
      last if $inloop++;  # We've been here before
    } elsif ($f != 1) {
      push @factors, $f;
      push @factors, int($n/$f);
      croak "internal error in prho" unless ($f * int($n/$f)) == $n;
      return @factors;
    }
  }
  push @factors, $n;
  @factors;
}

sub pbrent_factor {
  my($n, $rounds) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  $rounds = 4*1024*1024 unless defined $rounds;

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  my $a = 11;
  my $Xi = 2;
  my $Xm = 2;

  for my $i (1 .. $rounds) {
    # Xi^2+a % n
    $Xi = _mulmod($Xi, $Xi, $n);
    $Xi = (($n-$Xi) > $a)  ?  $Xi+$a  :  $Xi+$a-$n;
    my $f = _gcd_ui( ($Xi > $Xm) ? $Xi-$Xm : $Xm-$Xi,  $n );
    if ( ($f != 1) && ($f != $n) ) {
      push @factors, $f;
      push @factors, int($n/$f);
      croak "internal error in pbrent" unless ($f * int($n/$f)) == $n;
      return @factors;
    }
    $Xm = $Xi if ($i & ($i-1)) == 0;  # i is a power of 2
  }
  push @factors, $n;
  @factors;
}

sub pminus1_factor {
  my($n, $rounds) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  $rounds = 4*1024*1024 unless defined $rounds;

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  my $kf = 13;

  for my $i (1 .. $rounds) {
    $kf = _powmod($kf, $i, $n);
    $kf = $n if $kf == 0;
    my $f = _gcd_ui( $kf-1, $n );
    if ( ($f != 1) && ($f != $n) ) {
      push @factors, $f;
      push @factors, int($n/$f);
      croak "internal error in pminus1" unless ($f * int($n/$f)) == $n;
      return @factors;
    }
  }
  push @factors, $n;
  @factors;
}

sub holf_factor {
  my($n, $rounds) = @_;
  croak "Input must be a positive integer" unless _is_positive_int($n);
  $rounds = 64*1024*1024 unless defined $rounds;

  my @factors = _basic_factor($n);
  return @factors if $n < 4;

  for my $i (1 .. $rounds) {
    my $s = int(sqrt($n * $i));
    $s++ if ($s * $s) != ($n * $i);
    my $m = _mulmod($s, $s, $n);
    # Check for perfect square
    my $mcheck = $m & 127;
    next if (($mcheck*0x8bc40d7d) & ($mcheck*0xa1e2f5d1) & 0x14020a);
    my $f = int(sqrt($m));
    next unless $f*$f == $m;
    $f = _gcd_ui( ($s > $f)  ?  $s - $f  :  $f - $s,  $n);
    last if $f == 1 || $f == $n;   # Should never happen
    push @factors, $f;
    push @factors, int($n/$f);
    croak "internal error in HOLF" unless ($f * int($n/$f)) == $n;
    # print "HOLF found factors in $i rounds\n";
    return @factors;
  }
  push @factors, $n;
  @factors;
}

my $_const_euler = 0.57721566490153286060651209008240243104215933593992;
my $_const_li2 = 1.045163780117492784844588889194613136522615578151;

sub ExponentialIntegral {
  my($x) = @_;
  my $tol = 1e-16;
  my $sum = 0.0;
  my($y, $t);
  my $c = 0.0;

  croak "Invalid input to ExponentialIntegral:  x must be != 0" if $x == 0;

  my $val; # The result from one of the four methods

  if ($x < -1) {
    # Continued fraction
    my $lc = 0;
    my $ld = 1 / (1 - $x);
    $val = $ld * (-exp($x));
    for my $n (1 .. 100000) {
      $lc = 1 / (2*$n + 1 - $x - $n*$n*$lc);
      $ld = 1 / (2*$n + 1 - $x - $n*$n*$ld);
      my $old = $val;
      $val *= $ld/$lc;
      last if abs($val - $old) <= ($tol * abs($val));
    }
  } elsif ($x < 0) {
    # Rational Chebyshev approximation
    my @C6p = ( -148151.02102575750838086,
                 150260.59476436982420737,
                  89904.972007457256553251,
                  15924.175980637303639884,
                   2150.0672908092918123209,
                    116.69552669734461083368,
                      5.0196785185439843791020);
    my @C6q = (  256664.93484897117319268,
                 184340.70063353677359298,
                  52440.529172056355429883,
                   8125.8035174768735759866,
                    750.43163907103936624165,
                     40.205465640027706061433,
                      1.0000000000000000000000);
    my $sumn = $C6p[0]-$x*($C6p[1]-$x*($C6p[2]-$x*($C6p[3]-$x*($C6p[4]-$x*($C6p[5]-$x*$C6p[6])))));
    my $sumd = $C6q[0]-$x*($C6q[1]-$x*($C6q[2]-$x*($C6q[3]-$x*($C6q[4]-$x*($C6q[5]-$x*$C6q[6])))));
    $val = log(-$x) - ($sumn / $sumd);
  } elsif ($x < -log($tol)) {
    # Convergent series
    my $fact_n = 1;
    $y = $_const_euler-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
    $y = log($x)-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
    for my $n (1 .. 200) {
      $fact_n *= $x/$n;
      my $term = $fact_n / $n;
      $y = $term-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
      last if $term < $tol;
    }
    $val = $sum;
  } else {
    # Asymptotic divergent series
    $val = exp($x) / $x;
    $y = 1.0-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
    my $term = 1.0;
    for my $n (1 .. 200) {
      my $last_term = $term;
      $term *= $n/$x;
      last if $term < $tol;
      if ($term < $last_term) {
        $y = $term-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
      } else {
        $y = (-$last_term/3)-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
        last;
      }
    }
    $val *= $sum;
  }
  $val;
}

sub LogarithmicIntegral {
  my($x) = @_;
  return 0 if $x == 0;
  return 0+(-Infinity) if $x == 1;
  return $_const_li2 if $x == 2;
  croak "Invalid input to LogarithmicIntegral:  x must be > 0" if $x <= 0;
  ExponentialIntegral(log($x));
}

# Riemann Zeta function for integers, used for computing Riemann R
my @_Riemann_Zeta_Table = (
  0.6449340668482264364724151666460251892,  # zeta(2)
  0.2020569031595942853997381615114499908,
  0.0823232337111381915160036965411679028,
  0.0369277551433699263313654864570341681,
  0.0173430619844491397145179297909205279,
  0.0083492773819228268397975498497967596,
  0.0040773561979443393786852385086524653,
  0.0020083928260822144178527692324120605,
  0.0009945751278180853371459589003190170,
  0.0004941886041194645587022825264699365,
  0.0002460865533080482986379980477396710,
  0.0001227133475784891467518365263573957,
  0.0000612481350587048292585451051353337,
  0.0000305882363070204935517285106450626,
  0.0000152822594086518717325714876367220,
  0.0000076371976378997622736002935630292,
  0.0000038172932649998398564616446219397,
  0.0000019082127165539389256569577951013,
  0.0000009539620338727961131520386834493,
  0.0000004769329867878064631167196043730,
  0.0000002384505027277329900036481867530,
  0.0000001192199259653110730677887188823,
  0.0000000596081890512594796124402079358,
  0.0000000298035035146522801860637050694,
  0.0000000149015548283650412346585066307,
  0.0000000074507117898354294919810041706,
  0.0000000037253340247884570548192040184,
  0.0000000018626597235130490064039099454,
  0.0000000009313274324196681828717647350,
  0.0000000004656629065033784072989233251,
  0.0000000002328311833676505492001455976,
  0.0000000001164155017270051977592973835,
  0.0000000000582077208790270088924368599,
  0.0000000000291038504449709968692942523,
  0.0000000000145519218910419842359296322,
  0.0000000000072759598350574810145208690,
  0.0000000000036379795473786511902372363,
  0.0000000000018189896503070659475848321,
  0.0000000000009094947840263889282533118,
);

# Compute Riemann Zeta function.  Slow and inaccurate near x = 1, but improves
# very rapidly (x = 5 is quite reasonable).
sub _evaluate_zeta {
  my($x) = @_;
  my $tol = 1e-16;
  my $sum = 0.0;
  my($y, $t);
  my $c = 0.0;

  $y = (1.0/(2.0**$x))-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;

  for my $k (3 .. 100000) {
    my $term = 1.0 / ($k ** $x);
    $y = $term-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
    last if abs($term) < $tol;
  }
  $sum;
}

# Riemann R function
sub RiemannR {
  my($x) = @_;
  my $tol = 1e-16;
  my $sum = 0.0;
  my($y, $t);
  my $c = 0.0;

  croak "Invalid input to ReimannR:  x must be > 0" if $x <= 0;

  $y = 1.0-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
  my $flogx = log($x);
  my $part_term = 1.0;

  for my $k (1 .. 10000) {
    # Small k from table, larger k from function
    my $zeta = ($k <= $#_Riemann_Zeta_Table) ? $_Riemann_Zeta_Table[$k+1-2]
                                             : _evaluate_zeta($k+1);
    $part_term *= $flogx / $k;
    my $term = $part_term / ($k + $k * $zeta);
    $y = $term-$c; $t = $sum+$y; $c = ($t-$sum)-$y; $sum = $t;
    last if abs($term) < $tol;
  }
  $sum;
}

1;

__END__


# ABSTRACT: Pure Perl version of Math::Prime::Util

=pod

=head1 NAME

Math::Prime::Util::PP - Pure Perl version of Math::Prime::Util


=head1 VERSION

Version 0.09


=head1 SYNOPSIS

The functionality is basically identical to L<Math::Prime::Util>, as this
module is just the Pure Perl implementation.

  # Normally you would just import the functions you are using.
  # Nothing is exported by default.
  use Math::Prime::Util ':all';


  # Get a big array reference of many primes
  my $aref = primes( 100_000_000 );

  # All the primes between 5k and 10k inclusive
  my $aref = primes( 5_000, 10_000 );

  # If you want them in an array instead
  my @primes = @{primes( 500 )};


  # is_prime returns 0 for composite, 2 for prime
  say "$n is prime"  if is_prime($n);

  # is_prob_prime returns 0 for composite, 2 for prime, and 1 for maybe prime
  say "$n is ", qw(composite maybe_prime? prime)[is_prob_prime($n)];


  # step to the next prime (returns 0 if the next one is more than ~0)
  $n = next_prime($n);

  # step back (returns 0 if given input less than 2)
  $n = prev_prime($n);


  # Return Pi(n) -- the number of primes E<lt>= n.
  $primepi = prime_count( 1_000_000 );
  $primepi = prime_count( 10**14, 10**14+1000 );  # also does ranges

  # Quickly return an approximation to Pi(n)
  my $approx_number_of_primes = prime_count_approx( 10**17 );

  # Lower and upper bounds.  lower <= Pi(n) <= upper for all n
  die unless prime_count_lower($n) <= prime_count($n);
  die unless prime_count_upper($n) >= prime_count($n);


  # Return p_n, the nth prime
  say "The ten thousandth prime is ", nth_prime(10_000);

  # Return a quick approximation to the nth prime
  say "The one trillionth prime is ~ ", nth_prime_approx(10**12);

  # Lower and upper bounds.   lower <= nth_prime(n) <= upper for all n
  die unless nth_prime_lower($n) <= nth_prime($n);
  die unless nth_prime_upper($n) >= nth_prime($n);


  # Get the prime factors of a number
  @prime_factors = factor( $n );


  # Precalculate a sieve, possibly speeding up later work.
  prime_precalc( 1_000_000_000 );

  # Free any memory used by the module.
  prime_memfree;

  # Alternate way to free.  When this leaves scope, memory is freed.
  my $mf = Math::Prime::Util::MemFree->new;


  # Random primes
  my $small_prime = random_prime(1000);      # random prime <= limit
  my $rand_prime = random_prime(100, 10000); # random prime within a range
  my $rand_prime = random_ndigit_prime(6);   # random 6-digit prime


=head1 DESCRIPTION

A set of utilities related to prime numbers.  These include multiple sieving
methods, is_prime, prime_count, nth_prime, approximations and bounds for
the prime_count and nth prime, next_prime and prev_prime, factoring utilities,
and more.

All routines currently work in native integers (32-bit or 64-bit).  Bignum
support may be added later.  If you need bignum support for these types of
functions inside Perl now, I recommend L<Math::Pari>.


=head1 FUNCTIONS

=head2 is_prime

  print "$n is prime" if is_prime($n);

Returns 2 if the number is prime, 0 if not.  Also note there are
probabilistic prime testing functions available.


=head2 primes

Returns all the primes between the lower and upper limits (inclusive), with
a lower limit of C<2> if none is given.

An array reference is returned (with large lists this is much faster and uses
less memory than returning an array directly).

  my $aref1 = primes( 1_000_000 );
  my $aref2 = primes( 1_000_000_000_000, 1_000_000_001_000 );

  my @primes = @{ primes( 500 ) };

  print "$_\n" for (@{primes( 20, 100 )});

Sieving will be done if required.  The algorithm used will depend on the range
and whether a sieve result already exists.  Possibilities include trial
division (for ranges with only one expected prime), a Sieve of Eratosthenes
using wheel factorization, or a segmented sieve.


=head2 next_prime

  $n = next_prime($n);

Returns the next prime greater than the input number.  0 is returned if the
next prime is larger than a native integer type (the last representable
primes being C<4,294,967,291> in 32-bit Perl and
C<18,446,744,073,709,551,557> in 64-bit).


=head2 prev_prime

  $n = prev_prime($n);

Returns the prime smaller than the input number.  0 is returned if the
input is C<2> or lower.


=head2 prime_count

  my $primepi = prime_count( 1_000 );
  my $pirange = prime_count( 1_000, 10_000 );

Returns the Prime Count function C<Pi(n)>, also called C<primepi> in some
math packages.  When given two arguments, it returns the inclusive
count of primes between the ranges (e.g. C<(13,17)> returns 2, C<14,17>
and C<13,16> return 1, and C<14,16> returns 0).


=head2 prime_count_upper

=head2 prime_count_lower

  my $lower_limit = prime_count_lower($n);
  die unless prime_count($n) >= $lower_limit;

  my $upper_limit = prime_count_upper($n);
  die unless prime_count($n) <= $upper_limit;

Returns an upper or lower bound on the number of primes below the input number.
These are analytical routines, so will take a fixed amount of time and no
memory.  The actual C<prime_count> will always be on or between these numbers.

A common place these would be used is sizing an array to hold the first C<$n>
primes.  It may be desirable to use a bit more memory than is necessary, to
avoid calling C<prime_count>.

These routines use hand-verified tight limits below a range at least C<2^35>,
and fall back to the Dusart bounds of

    x/logx * (1 + 1/logx + 1.80/log^2x) <= Pi(x)

    x/logx * (1 + 1/logx + 2.51/log^2x) >= Pi(x)

above that range.


=head2 prime_count_approx

  print "there are about ",
        prime_count_approx( 10 ** 18 ),
        " primes below one quintillion.\n";

Returns an approximation to the C<prime_count> function, without having to
generate any primes.  The current implementation uses the Riemann R function
which is quite accurate: an error of less than C<0.0005%> is typical for
input values over C<2^32>.  A slightly faster (0.1ms vs. 1ms), but much less
accurate, answer can be obtained by averaging the upper and lower bounds.


=head2 nth_prime

  say "The ten thousandth prime is ", nth_prime(10_000);

Returns the prime that lies in index C<n> in the array of prime numbers.  Put
another way, this returns the smallest C<p> such that C<Pi(p) E<gt>= n>.

This relies on generating primes, so can require a lot of time and space for
large inputs.


=head2 nth_prime_upper

=head2 nth_prime_lower

  my $lower_limit = nth_prime_lower($n);
  die unless nth_prime($n) >= $lower_limit;

  my $upper_limit = nth_prime_upper($n);
  die unless nth_prime($n) <= $upper_limit;

Returns an analytical upper or lower bound on the Nth prime.  This will be
very fast.  The lower limit uses the Dusart 1999 bounds for all C<n>, while
the upper bound uses one of the two Dusart 1999 bounds for C<n E<gt>= 27076>,
the Robin 1983 bound for C<n E<gt>= 7022>, and the simple bound of
C<n * (logn + loglogn)> for C<n E<lt> 7022>.


=head2 nth_prime_approx

  say "The one trillionth prime is ~ ", nth_prime_approx(10**12);

Returns an approximation to the C<nth_prime> function, without having to
generate any primes.  Uses the Cipolla 1902 approximation with two
polynomials, plus a correction term for small values to reduce the error.


=head2 miller_rabin

  my $maybe_prime = miller_rabin($n, 2);
  my $probably_prime = miller_rabin($n, 2, 3, 5, 7, 11, 13, 17);

Takes a positive number as input and one or more bases.  The bases must be
between C<2> and C<n - 2>.  Returns 2 is C<n> is definitely prime, 1 if C<n>
is probably prime, and 0 if C<n> is definitely composite.  Since this is
just the Miller-Rabin test, a value of 2 is only returned for inputs of
2 and 3, which are shortcut.  If 0 is returned, then the number really is a
composite.  If 1 is returned, there is a good chance the number is prime
(depending on the input and the bases), but we cannot be sure.

This is usually used in combination with other tests to make either stronger
tests (e.g. the strong BPSW test) or deterministic results for numbers less
than some verified limit (such as the C<is_prob_prime> function in this module).


=head2 is_prob_prime

  my $prob_prime = is_prob_prime($n);
  # Returns 0 (composite), 2 (prime), or 1 (probably prime)

Takes a positive number as input and returns back either 0 (composite),
2 (definitely prime), or 1 (probably prime).

This is done with a tuned set of Miller-Rabin tests such that the result
will be deterministic for 64-bit input.  Either 2, 3, 4, 5, or 7 Miller-Rabin
tests are performed (no more than 3 for 32-bit input), and the result will
then always be 0 (composite) or 2 (prime).  A later implementation may switch
to a BPSW test, depending on speed.


=head2 random_prime

  my $small_prime = random_prime(1000);      # random prime <= limit
  my $rand_prime = random_prime(100, 10000); # random prime within a range

Returns a psuedo-randomly selected prime that will be greater than or equal
to the lower limit and less than or equal to the upper limit.  If no lower
limit is given, 2 is implied.  Returns undef if no primes exist within the
range.  The L<rand> function is called one or more times for selection.

This will return a uniform distribution of the primes in the range, meaning
for each prime in the range, the chances are equally likely that it will be
seen.

The current algorithm does a random index selection for small numbers, which
is deterministic.  For larger numbers, this can be very slow, so the
obvious Monte Carlo method is used, where random numbers in the range are
selected until one is prime.  That also gets slow as the number of digits
increases, but not something that impacts us in 64-bit.

If you want cryptographically secure primes, I suggest looking at
L<Crypt::Primes> or something similar.  The current L<Math::Prime::Util>
module does not use strong randomness, and its primes are ridiculously small
by cryptographic standards.

Perl's L<rand> function is normally called, but if the sub C<main::rand>
exists, it will be used instead.  When called with no arguments it should
return a float value between 0 and 1-epsilon, with 32 bits of randomness.
Examples:

  # Use Mersenne Twister
  use Math::Random::MT::Auto qw/rand/;

  # Use my custom random function
  sub rand { ... }

=head2 random_ndigit_prime

  say "My 4-digit prime number is: ", random_ndigit_prime(4);

Selects a random n-digit prime, where the input is an integer number of
digits between 1 and the maximum native type (10 for 32-bit, 20 for 64-bit).
One of the primes within that range (e.g. 1000 - 9999 for 4-digits) will be
uniformly selected using the L<rand> function.



=head1 UTILITY FUNCTIONS

=head2 prime_precalc

  prime_precalc( 1_000_000_000 );

Let the module prepare for fast operation up to a specific number.  It is not
necessary to call this, but it gives you more control over when memory is
allocated and gives faster results for multiple calls in some cases.  In the
current implementation this will calculate a sieve for all numbers up to the
specified number.


=head2 prime_memfree

  prime_memfree;

Frees any extra memory the module may have allocated.  Like with
C<prime_precalc>, it is not necessary to call this, but if you're done
making calls, or want things cleanup up, you can use this.  The object method
might be a better choice for complicated uses.

=head2 Math::Prime::Util::MemFree->new

  my $mf = Math::Prime::Util::MemFree->new;
  # perform operations.  When $mf goes out of scope, memory will be recovered.

This is a more robust way of making sure any cached memory is freed, as it
will be handled by the last C<MemFree> object leaving scope.  This means if
your routines were inside an eval that died, things will still get cleaned up.
If you call another function that uses a MemFree object, the cache will stay
in place because you still have an object.



=head1 FACTORING FUNCTIONS

=head2 factor

  my @factors = factor(3_369_738_766_071_892_021);
  # returns (204518747,16476429743)

Produces the prime factors of a positive number input.  They may not be in
numerical order.  The special cases of C<n = 0> and C<n = 1> will
return C<n>, which guarantees multiplying the factors together will
always result in the input value, though those are the only cases where
the returned factors are not prime.

The current algorithm is to use trial division for small numbers, while large
numbers go through a sequence of small trials, SQUFOF, Pollard's Rho, Hart's
one line factorization, and finally trial division for any survivors.  This
process is repeated for each non-prime factor.


=head2 all_factors

  my @divisors = all_factors(30);   # returns (2, 3, 5, 6, 10, 15)

Produces all the divisors of a positive number input.  1 and the input number
are excluded (which implies that an empty list is returned for any prime
number input).  The divisors are a power set of multiplications of the prime
factors, returned as a uniqued sorted list.


=head2 trial_factor

  my @factors = trial_factor($n);

Produces the prime factors of a positive number input.  The factors will be
in numerical order.  The special cases of C<n = 0> and C<n = 1> will return
C<n>, while with all other inputs the factors are guaranteed to be prime.
For large inputs this will be very slow.

=head2 fermat_factor

  my @factors = fermat_factor($n);

Produces factors, not necessarily prime, of the positive number input.  The
particular algorithm is Knuth's algorithm C.  For small inputs this will be
very fast, but it slows down quite rapidly as the number of digits increases.
It is very fast for inputs with a factor close to the midpoint
(e.g. a semiprime p*q where p and q are the same number of digits).

=head2 holf_factor

  my @factors = holf_factor($n);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  It is possible
the function will be unable to find a factor, in which case a single element,
the input, is returned.  This uses Hart's One Line Factorization with no
premultiplier.  It is an interesting alternative to Fermat's algorithm,
and there are some inputs it can rapidly factor.  In the long run it has the
same advantages and disadvantages as Fermat's method.

=head2 squfof_factor

  my @factors = squfof_factor($n);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  It is possible
the function will be unable to find a factor, in which case a single element,
the input, is returned.  This function typically runs very fast.

=head2 prho_factor

=head2 pbrent_factor

=head2 pminus1_factor

  my @factors = prho_factor($n);

  # Use a very small number of rounds
  my @factors = prho_factor($n, 1000);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  These attempt
to find a single factor using one of the probabilistic algorigthms of
Pollard Rho, Brent's modification of Pollard Rho, or Pollard's C<p - 1>.
These are more specialized algorithms usually used for pre-factoring very
large inputs, or checking very large inputs for naive mistakes.  If the
input is prime or they run out of rounds, they will return the single
input value.  On some inputs they will take a very long time, while on
others they succeed in a remarkably short time.



=head1 MATHEMATICAL FUNCTIONS

=head2 ExponentialIntegral

  my $Ei = ExponentialIntegral($x);

Given a non-zero floating point input C<x>, this returns the real-valued
exponential integral of C<x>, defined as the integral of C<e^t/t dt>
from C<-infinity> to C<x>.
Depending on the input, the integral is calculated using
continued fractions (C<x E<lt> -1>),
rational Chebyshev approximation (C< -1 E<lt> x E<lt> 0>),
a convergent series (small positive C<x>),
or an asymptotic divergent series (large positive C<x>).

Accuracy should be at least 14 digits.


=head2 LogarithmicIntegral

  my $li = LogarithmicIntegral($x)

Given a positive floating point input, returns the floating point logarithmic
integral of C<x>, defined as the integral of C<dt/ln t> from C<0> to C<x>.
If given a negative input, the function will croak.  The function returns
0 at C<x = 0>, and C<-infinity> at C<x = 1>.

This is often known as C<li(x)>.  A related function is the offset logarithmic
integral, sometimes known as C<Li(x)> which avoids the singularity at 1.  It
may be defined as C<Li(x) = li(x) - li(2)>.

This function is implemented as C<li(x) = Ei(ln x)> after handling special
values.

Accuracy should be at least 14 digits.


=head2 RiemannR

  my $r = RiemannR($x);

Given a positive non-zero floating point input, returns the floating
point value of Riemann's R function.  Riemann's R function gives a very close
approximation to the prime counting function.

Accuracy should be at least 14 digits.


=head1 LIMITATIONS

The SQUFOF and Fermat factoring algorithms are not implemented yet.

Some of the prime methods use more memory than they should, as the segmented
sieve is not properly used in C<primes> and C<prime_count>.


=head1 PERFORMANCE

Performance compared to the XS/C code is quite poor for many operations.  Some
operations that are relatively close for small and medium-size values:

  next_prime / prev_prime
  is_prime / is_prob_prime
  miller_rabin
  ExponentialIntegral / LogarithmicIntegral / RiemannR
  primearray

Operations that are slower include:

  primes
  random_prime / random_ndigit_prime
  factor / all_factors
  nth_prime
  primecount

Performance improvement in this code is still possible.  The prime sieve is
over 2x faster than anything I was able to find online, but it is still has
room for improvement.

Fundamentally some of these operations will be much faster in C than Perl.  I
expect any of the CPAN XS modules supporting related features to be faster,
however if those modules are available, then the XS code in
L<Math::Prime::Util> should be.

Memory use will generally be higher for the PP code, and in some cases B<much>
higher.  Some of this may be addressed in a later release.

For small values (e.g. primes and prime counts under 10M) most of this will
not matter.  


=head1 SEE ALSO

L<Math::Prime::Util>


=head1 AUTHORS

Dana Jacobsen E<lt>dana@acm.orgE<gt>


=head1 COPYRIGHT

Copyright 2012 by Dana Jacobsen E<lt>dana@acm.orgE<gt>

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
