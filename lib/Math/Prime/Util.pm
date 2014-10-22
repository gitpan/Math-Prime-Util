package Math::Prime::Util;
use strict;
use warnings;
use Carp qw/croak confess carp/;

BEGIN {
  $Math::Prime::Util::AUTHORITY = 'cpan:DANAJ';
  $Math::Prime::Util::VERSION = '0.10';
}

# parent is cleaner, and in the Perl 5.10.1 / 5.12.0 core, but not earlier.
# use parent qw( Exporter );
use base qw( Exporter );
our @EXPORT_OK = qw(
                     prime_get_config
                     prime_precalc prime_memfree
                     is_prime is_prob_prime
                     is_strong_pseudoprime is_strong_lucas_pseudoprime
                     miller_rabin
                     primes
                     next_prime  prev_prime
                     prime_count prime_count_lower prime_count_upper prime_count_approx
                     nth_prime nth_prime_lower nth_prime_upper nth_prime_approx
                     random_prime random_ndigit_prime random_nbit_prime random_maurer_prime
                     factor all_factors moebius euler_phi
                     ExponentialIntegral LogarithmicIntegral RiemannR
                   );
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);

# Similar to how boolean handles its option
sub import {
    my @options = grep $_ ne '-nobigint', @_;
    $_[0]->_import_nobigint if @options != @_;
    @_ = @options;
    goto &Exporter::import;
}

sub _import_nobigint {
  undef *factor;        *factor          = \&_XS_factor;
  undef *is_prime;      *is_prime        = \&_XS_is_prime;
  undef *is_prob_prime; *is_prob_prime   = \&_XS_is_prob_prime;
  undef *next_prime;    *next_prime      = \&_XS_next_prime;
  undef *prev_prime;    *prev_prime      = \&_XS_prev_prime;
  undef *prime_count;   *prime_count     = \&_XS_prime_count;
  undef *nth_prime;     *nth_prime       = \&_XS_nth_prime;
  undef *is_strong_pseudoprime;  *is_strong_pseudoprime = \&_XS_miller_rabin;
  undef *miller_rabin;  *miller_rabin    = \&_XS_miller_rabin;
}

my %_Config;

BEGIN {

  # Load PP code.  Nothing exported.
  require Math::Prime::Util::PP;

  eval {
    require XSLoader;
    XSLoader::load(__PACKAGE__, $Math::Prime::Util::VERSION);
    prime_precalc(0);
    $_Config{'xs'} = 1;
    $_Config{'maxbits'} = _XS_prime_maxbits();
    1;
  } or do {
    $_Config{'xs'} = 0;
    $_Config{'maxbits'} = Math::Prime::Util::PP::_PP_prime_maxbits();
    carp "Using Pure Perl implementation: $@";

    *_prime_memfreeall = \&Math::Prime::Util::PP::_prime_memfreeall;
    *prime_memfree  = \&Math::Prime::Util::PP::prime_memfree;
    *prime_precalc  = \&Math::Prime::Util::PP::prime_precalc;

    # These probably shouldn't even be exported
    *trial_factor   = \&Math::Prime::Util::PP::trial_factor;
    *fermat_factor  = \&Math::Prime::Util::PP::fermat_factor;
    *holf_factor    = \&Math::Prime::Util::PP::holf_factor;
    *squfof_factor  = \&Math::Prime::Util::PP::squfof_factor;
    *pbrent_factor  = \&Math::Prime::Util::PP::pbrent_factor;
    *prho_factor    = \&Math::Prime::Util::PP::prho_factor;
    *pminus1_factor = \&Math::Prime::Util::PP::pminus1_factor;
  };

  # See if they have the GMP module
  $_Config{'gmp'} = 0;
  $_Config{'gmp'} = 1 if eval { require Math::Prime::Util::GMP;
                                Math::Prime::Util::GMP->import();
                                1; };
}
END {
  _prime_memfreeall;
}

if ($_Config{'maxbits'} == 32) {
  $_Config{'maxparam'}    = 4294967295;
  $_Config{'maxdigits'}   = 10;
  $_Config{'maxprime'}    = 4294967291;
  $_Config{'maxprimeidx'} = 203280221;
} else {
  $_Config{'maxparam'}    = 18446744073709551615;
  $_Config{'maxdigits'}   = 20;
  $_Config{'maxprime'}    = 18446744073709551557;
  $_Config{'maxprimeidx'} = 425656284035217743;
}

# used for code like:
#    return _XS_foo($n)  if $n <= $_XS_MAXVAL
# which builds into one scalar whether XS is available and if we can call it.
my $_XS_MAXVAL = $_Config{'xs'}  ?  $_Config{'maxparam'}  :  -1;
my $_HAVE_GMP = $_Config{'gmp'};

# Notes on how we're dealing with big integers:
#
#  1) if (ref($n) eq 'Math::BigInt')
#     $n is a bigint, so do bigint stuff
#
#  2) if (defined $bigint::VERSION && $n > ~0)
#     make $n into a bigint.  This is debatable, but they *did* hand us a
#     string with a big integer in it.  The big gotcha here is that
#     is_strong_lucas_pseudoprime does bigint computations, so it will load
#     up bigint and there is no way to unload it.
#
#  3) if (ref($n) =~ /^Math::Big/)
#     $n is a big int, float, or rat.  We probably want this as an int.
#
#  $n = $n->numify if $n < ~0 && ref($n) =~ /^Math::Big/;
#     get us out of big math if we can
#
# Sadly, non-modern versions of bignum (5.12.4 and earlier) completely make a
# mess of things like BigInt::numify and int(BigFloat).  Using int($x->bstr)
# seems to work.
# E.g.:
#    $n = 33662485846146713;  $n->numify;   $n is now 3.36624858461467e+16


sub prime_get_config {
  my %config = %_Config;

  $config{'precalc_to'} = ($_Config{'xs'})
                        ? _get_prime_cache_size()
                        : Math::Prime::Util::PP::_get_prime_cache_size;

  return \%config;

}

sub _validate_positive_integer {
  my($n, $min, $max) = @_;
  croak "Parameter must be defined" if !defined $n;
  croak "Parameter '$n' must be a positive integer" if $n =~ tr/0123456789//c;
  croak "Parameter '$n' must be >= $min" if defined $min && $n < $min;
  croak "Parameter '$n' must be <= $max" if defined $max && $n > $max;
  if ($n <= $_Config{'maxparam'}) {
    $_[0] = $_[0]->as_number() if ref($_[0]) eq 'Math::BigFloat';
    $_[0] = int($_[0]->bstr) if ref($_[0]) eq 'Math::BigInt';
  } elsif (ref($n) ne 'Math::BigInt') {
    croak "Parameter '$n' outside of integer range" if !defined $bigint::VERSION;
    $_[0] = Math::BigInt->new("$n"); # Make $n a proper bigint object
  }
  # One of these will be true:
  #     1) $n <= max and $n is not a bigint
  #     2) $n  > max and $n is a bigint
  1;
}

# It you use bigint then call one of the approx/bounds/math functions, you'll
# end up with full bignum turned on.  This seems non-optimal.  However, if I
# don't do this, then you'll get wrong results and end up with it turned on
# _anyway_.  As soon as anyone does something like log($n) where $n is a
# Math::BigInt, it auto-upgrade and loads up Math::BigFloat.
#
# Ideally we'd notice we were causing this, and turn off Math::BigFloat after
# we were done.
sub _upgrade_to_float {
  my($n) = @_;
  return $n unless defined $Math::BigInt::VERSION || defined $Math::BigFloat::VERSION;
  do { require Math::BigFloat; Math::BigFloat->import; } if defined $Math::BigInt::VERSION && !defined $Math::BigFloat::VERSION;
  return Math::BigFloat->new($n);
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
#my @_prime_next_small = (
#   2,2,3,5,5,7,7,11,11,11,11,13,13,17,17,17,17,19,19,23,23,23,23,
#   29,29,29,29,29,29,31,31,37,37,37,37,37,37,41,41,41,41,43,43,47,
#   47,47,47,53,53,53,53,53,53,59,59,59,59,59,59,61,61,67,67,67,67,67,67,71);





#############################################################################

sub primes {
  my $optref = (ref $_[0] eq 'HASH')  ?  shift  :  {};
  croak "no parameters to primes" unless scalar @_ > 0;
  croak "too many parameters to primes" unless scalar @_ <= 2;
  my $low = (@_ == 2)  ?  shift  :  2;
  my $high = shift;

  _validate_positive_integer($low);
  _validate_positive_integer($high);

  my $sref = [];
  return $sref if ($low > $high) || ($high < 2);

  if ($high > $_XS_MAXVAL) {
    return Math::Prime::Util::GMP::primes($low,$high) if $_HAVE_GMP;
    return Math::Prime::Util::PP::primes($low,$high);
  }

  my $method = $optref->{'method'};
  $method = 'Dynamic' unless defined $method;

  if ($method =~ /^(Dyn\w*|Default|Generate)$/i) {
    # Dynamic -- we should try to do something smart.

    # Tiny range?
    if (($low+1) >= $high) {
      $method = 'Trial';

    # Fast for cached sieve?
    } elsif (($high <= (65536*30)) || ($high <= _get_prime_cache_size())) {
      $method = 'Sieve';

    # More memory than we should reasonably use for base sieve?
    } elsif ($high > (32*1024*1024*30)) {
      $method = 'Segment';

    # Only want half or less of the range low-high ?
    } elsif ( int($high / ($high-$low)) >= 2 ) {
      $method = 'Segment';

    } else {
      $method = 'Sieve';
    }
  }

  if ($method =~ /^Simple\w*$/i) {
    carp "Method 'Simple' is deprecated.";
    $method = 'Erat';
  }

  if    ($method =~ /^Trial$/i)     { $sref = trial_primes($low, $high); }
  elsif ($method =~ /^Erat\w*$/i)   { $sref = erat_primes($low, $high); }
  elsif ($method =~ /^Seg\w*$/i)    { $sref = segment_primes($low, $high); }
  elsif ($method =~ /^Sieve$/i)     { $sref = sieve_primes($low, $high); }
  else { croak "Unknown prime method: $method"; }

  # Using this line:
  #   return (wantarray) ? @{$sref} : $sref;
  # would allow us to return an array ref in scalar context, and an array
  # in array context.  Handy for people who might write:
  #   @primes = primes(100);
  # but I think the dual interface could bite us later.
  return $sref;
}


# For random primes, there are two good papers that should be examined:
#
#  "Fast Generation of Prime Numbers and Secure Public-Key Cryptographic Parameters"
#  by Ueli M. Maurer, 1995
#  http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.26.2151
#  related discussions:
#      http://www.daimi.au.dk/~ivan/provableprimesproject.pdf
#      Handbook of Applied Cryptography by Menezes, et al.
#
#  "Close to Uniform Prime Number Generation With Fewer Random Bits"
#   by Pierre-Alain Fouque and Mehdi Tibouchi, 2011
#   http://eprint.iacr.org/2011/481
#
#
#  Some things to note:
#
#    1) Joye and Paillier have patents on their methods.  Never use them.
#
#    2) The easy-peasy method of next_prime(random number) is fast but gives
#       a terribly distribution, and not only in the obvious positive bias.
#       The probability for a prime is proportional to its gap, which is
#       really a bad distribution.
#
# For standard random primes, the implementation is very similar to Fouque's
# Algorithm 1.  For ranges of 32-bits or less, the distribution is uniform.
# For larger ranges it is very close (See Foque/Tibouchi).
#
# The random_maurer_prime function uses Maurer's algorithm of course.
#
# The current code is reasonably fast for native, but slow for bigints.  Using
# the M::P::U::GMP module helps immensely.  Performance does differ though --
# my 32-bit machine is ~5x slower than this 64-bit machine for this.
#
#    n-bits      no GMP      with MPU::GMP
#    ----------  ----------  --------------
#       24-bit         15uS                 (native)
#       64-bit         60uS                 (native)
#      128-bit       0.2s        0.01s
#      256-bit       1s          0.02s
#      512-bit      10s          0.03s
#     1024-bit     1m            0.1s
#     2048-bit    ~4m            0.6s
#     4096-bit   ~80m            7s
#     8192-bit   ----           80s
#
# To verify distribution:
#   perl -Iblib/lib -Iblib/arch -MMath::Prime::Util=:all -E 'my %freq; $n=1000000; $freq{random_nbit_prime(6)}++ for (1..$n); printf("%4d %6.3f%%\n", $_, 100.0*$freq{$_}/$n) for sort {$a<=>$b} keys %freq;'
#   perl -Iblib/lib -Iblib/arch -MMath::Prime::Util=:all -E 'my %freq; $n=1000000; $freq{random_prime(1260437,1260733)}++ for (1..$n); printf("%4d %6.3f%%\n", $_, 100.0*$freq{$_}/$n) for sort {$a<=>$b} keys %freq;'

{
  # Note:  I was using rand($range), but Math::Random::MT ignores the argument
  #        instead of following its documentation.
  my $irandf = sub {
     return int( (defined &::rand)  ?  ::rand()*$_[0]  :  rand()*$_[0] );
  };
  # TODO: Look at RANDBITS if using system rand
  my $rand_max_bits = 31;
  my $rand_max_val  = 1 << $rand_max_bits;

  # Returns a uniform number between [0,$range] inclusive.  The straightforward
  # method of getting a number of rand bits equal to the number of bits in the
  # number, then repeatedly get a random number in the bit range until it
  # falls within the desired range.
  my $get_rand_range = sub {
    my($range) = @_;
    return 0 if $range <= 0;
    my $rbits = 0;
    if (ref($range) eq 'Math::BigInt') {
      $rbits = length($range->as_bin) - 2;
    } else {
      my $t = $range;
      while ($t) { $rbits++; $t >>= 1; }
    }
    while (1) {
      my $rbitsleft = $rbits;
      my $U = $range - $range;   # zero in possible bigint
      while ($rbitsleft > 0) {
        my $usebits = ($rbitsleft > $rand_max_bits) ? $rand_max_bits : $rbitsleft;
        $U = ($U << $usebits) + $irandf->(1 << $usebits);
        $rbitsleft -= $usebits;
      }
      return $U if $U <= $range;
    }
  };

  # Sub to call with low and high already primes and verified range.
  my $_random_prime = sub {
    my($low,$high) = @_;
    my $prime;

    # { my $bsize = 100; my @bins; my $counts = 10000000;
    #   for my $c (1..$counts) { $bins[ $get_rand_range->($bsize) ]++; }
    #   for my $b (0..$bsize) {printf("%4d %8.5f%%\n", $b, $bins[$b]/$counts);}

    # low and high are both primes, and low < high.

    if ($high < 30000) {
      # nice deterministic solution, but gets very costly with large values.
      my $li = prime_count($low);
      my $hi = prime_count($high);
      my $irange = $hi - $li + 1;
      my $rand = $irandf->($irange);
      return nth_prime($li + $rand);
    }

    $low-- if $low == 2;  # Low of 2 becomes 1 for our program.
    croak "Invalid _random_prime parameters" if ($low % 2) == 0 || ($high % 2) == 0;

    # We're going to look at the odd numbers only.
    #my $range = $high - $low + 1;
    my $oddrange = int(($high - $low) / 2) + 1;

    # If $low is large (e.g. >10 digits) and $range is small (say ~10k), it
    # would be fastest to call primes in the range and randomly pick one.  I'm
    # not implementing it now because it seems like a rare case.

    if ($oddrange <= $rand_max_val) {
      $oddrange = int($oddrange->bstr) if ref($oddrange) eq 'Math::BigInt';
      # Our range is small enough we can just call rand once and be happy.
      # Generate random numbers in the interval until one is prime.
      my $loop_limit = 2000 * 1000;  # To protect against broken rand
      while (1) {
        $prime = $low + 2 * $irandf->($oddrange);
        croak "Random function broken?" if $loop_limit-- < 0;
        next if $prime > 11 && (!($prime % 3) || !($prime % 5) || !($prime % 7) || !($prime % 11));
        return 2 if $prime == 1;  # Remember the special case for 2.
        last if is_prime($prime);
      }
      return $prime;
    }

    # We have an ocean of range, and a teaspoon to hold randomness.

    # Since we have an arbitrary range and not a power of two, I don't see how
    # Fouque's algorithm A1 could be used (where we generate lower bits and
    # generate random sets of upper).  Similarly trying to simply generate
    # upper bits is full of ways to trip up and get non-uniform results.
    #
    # What I'm doing here is:
    #
    #   1) divide the range into semi-evenly sized partitions, where each part
    #      is as close to $rand_max_val as we can.
    #   2) randomly select one of the partitions.
    #   3) iterate choosing random values within the partition.

    my($binsize, $nparts);
    if (ref($oddrange) eq 'Math::BigInt') {
      # Go to some trouble here because some systems are wonky, such as
      # giving us +a/+b = -r.
      my($nbins, $rem);
      ($nbins, $rem) = $oddrange->copy->bdiv("$rand_max_val");
      $nbins++ if $rem > 0;
      ($binsize,$rem) = $oddrange->copy->bdiv($nbins);
      $binsize++ if $rem > 0;
      $nparts  = $oddrange->copy->bdiv($binsize);
    } else {
      my $nbins = int( ($oddrange + $rand_max_val - 1) / $rand_max_val );
      $binsize  = int( ($oddrange + $nbins - 1) / $nbins );
      $nparts   = int( $oddrange / $binsize );
    }
    $nparts-- if ($nparts * $binsize) == $oddrange;

    my $rpart = $get_rand_range->($nparts);

    my $primelow = $low + 2 * $binsize * $rpart;
    my $partsize = ($rpart < $nparts) ? $binsize
                                      : $oddrange - ($nparts * $binsize);
    $partsize = int($partsize->bstr) if ref($partsize) eq 'Math::BigInt';
    #warn "range $oddrange  = $nparts * $binsize + ", $oddrange - ($nparts * $binsize), "\n";
    #warn "  chose part $rpart size $partsize\n";
    #warn "  primelow is $low + 2 * $binsize * $rpart = $primelow\n";
    #die "Result could be too large" if ($primelow + 2*($partsize-1)) > $high;

    # Generate random numbers in the interval until one is prime.
    my $loop_limit = 2000 * 1000;  # To protect against broken rand
    while (1) {
      $prime = $primelow + ( 2 * $irandf->($partsize) );
      croak "random prime failure, $prime > $high" if $prime > $high;
      croak "Random function broken?" if $loop_limit-- < 0;
      # If we are a small int, then some mods are good.
      # If we're a bigint and have MPU:GMP installed then everything here is
      # wasteful.  If we're a bigint without MPU:GMP, then a bgcd is faster.
      next if $prime > 11 && (!($prime % 3) || !($prime % 5) || !($prime % 7) || !($prime % 11));
      do { $prime = 2; last; } if $prime == 1;   # special case for low = 2
      last if is_prime($prime);
    }
    return $prime;
  };
  # Cache of tight bounds for each digit.  Helps performance a lot.
  my @_random_ndigit_ranges = (undef, [2,7], [11,97] );
  my @_random_nbit_ranges   = (undef, undef, [2,3],[5,7] );

  sub random_prime {
    my $low = (@_ == 2)  ?  shift  :  2;
    my $high = shift;
    _validate_positive_integer($low);
    _validate_positive_integer($high);

    # Tighten the range to the nearest prime.
    $low = 2 if $low < 2;
    $low = next_prime($low - 1);
    $high = ($high < ~0)  ?  prev_prime($high + 1)  :  prev_prime($high);
    return $low if ($low == $high) && is_prime($low);
    return if $low >= $high;

    # At this point low and high are both primes, and low < high.
    return $_random_prime->($low, $high);
  }

  sub random_ndigit_prime {
    my($digits) = @_;
    _validate_positive_integer($digits, 1,
             (defined $bigint::VERSION) ? 10000 : $_Config{'maxdigits'});

    if (!defined $_random_ndigit_ranges[$digits]) {
      if ( defined $bigint::VERSION  &&  $digits >= $_Config{'maxdigits'} ) {
        my $low  = Math::BigInt->new('10')->bpow($digits-1);
        my $high = Math::BigInt->new('10')->bpow($digits);
        $_random_ndigit_ranges[$digits] = [next_prime($low), prev_prime($high)];
      } else {
        my $low  = int(10 ** ($digits-1));
        my $high = int(10 ** $digits);
        $high = ~0 if $high > ~0;
        $_random_ndigit_ranges[$digits] = [next_prime($low), prev_prime($high)];
      }
    }
    my ($low, $high) = @{$_random_ndigit_ranges[$digits]};
    return $_random_prime->($low, $high);
  }

  sub random_nbit_prime {
    my($bits) = @_;
    _validate_positive_integer($bits, 2,
             (defined $bigint::VERSION) ? 100000 : $_Config{'maxbits'});

    if (!defined $_random_nbit_ranges[$bits]) {
      if ( defined $bigint::VERSION  &&  $bits >= $_Config{'maxbits'} ) {
        my $low  = Math::BigInt->new('2')->bpow($bits-1);
        my $high = Math::BigInt->new('2')->bpow($bits);
        # Don't pull the range in to primes, just odds
        $_random_nbit_ranges[$bits] = [$low+1, $high-1];
      } else {
        #my $low  = int(2 ** ($bits-1));
        my $low  = 1 << ($bits-1);
        my $high = ~0 >> ($_Config{'maxbits'} - $bits);
        $_random_nbit_ranges[$bits] = [next_prime($low), prev_prime($high)];
      }
    }
    my ($low, $high) = @{$_random_nbit_ranges[$bits]};
    return $_random_prime->($low, $high);
  }

  sub random_maurer_prime {
    my($k) = @_;
    _validate_positive_integer($k, 2,
             (defined $bigint::VERSION) ? 100000 : $_Config{'maxbits'});

    my $p0 = 32;    # Use uniform random method for this many or less

    return random_nbit_prime($k) if $k <= $p0;

    use Math::BigInt;
    use Math::BigFloat;

    my $c = Math::BigFloat->new("0.09");  # higher = more trial divisions
    my $r = Math::BigFloat->new("0.5");
    my $m = 24;   # How much randomness we're trying to get at a time
    my $B = ($c * $k * $k)->bfloor;

    if ($k > 2*$m) {
      my $rbits = 0;
      while ($rbits <= $m) {
        my $s = Math::BigFloat->new( $irandf->($rand_max_val) )->bdiv($rand_max_val);
        my $r = Math::BigFloat->new(2)->bpow($s-1);
        $rbits = $k - ($r*$k);
      }
    }
    # I've seen +0, +1, and +2 here.  Menezes uses +1.
    my $q = random_maurer_prime( ($r * $k)->bfloor + 1 );
    #warn "B = $B  r = $r  k = $k  q = $q\n";
    my $I = Math::BigInt->new(2)->bpow($k-1)->bdiv(2 * $q)->bfloor;
    #warn "I = $I\n";

    my @primes = @{primes(17,$B)};

    while (1) {
      # R is a random number between $I+1 and 2*$I
      my $R = $I + 1 + $get_rand_range->( int($I - 1) );
      my $n = 2 * $R * $q + 1;
      # We constructed a promising looking $n.  Now test it.

      # Trial divide up to $B
      next if !($n % 3) || !($n % 5) || !($n % 7) || !($n % 11) || !($n % 13);
      if ($_HAVE_GMP) {
        next unless Math::Prime::Util::GMP::is_strong_pseudoprime($n, 2, 7);
      } else {
        my $looks_prime = 1;
        foreach my $p (@primes) {
          do { $looks_prime = 0; last; } if !($n % $p);
        }
        next unless $looks_prime;
      }
      #warn "$n passes trial division\n";

      # a is a random number between 2 and $n-2
      my $a = 2 + $get_rand_range->( $n - 4 );
      my $b = $a->copy->bmodpow($n-1, $n);
      next unless $b == 1;
      #warn "$n passes a^n-1 == 1\n";

      # We now get to choose between Maurer's original proposal:
      #   check gcd(a^((n-1)/q)-1,n)==1 for each factor q of n-1
      # thusly:

      $b = $a->copy->bmodpow(2*$R, $n);
      next unless Math::BigInt::bgcd($b-1, $n) == 1;
      #warn "$n passes final gcd\n";

      # Or via a different method, where we check q >= n**1/3 and also do
      # some tests on x & y from 2R = xq+y (see Lemma 2 from Maurer's paper).
      # Crypt::Primes does the q test but doesn't seem to do the x/y and
      # perfect square portions.
      #   next if ($q <= $n->copy->bpow(1/3));
      #   my $x = (2*$R)->bdiv($q)->bfloor;
      #   my $y = 2*$R - $x*$q;
      #   my $z = $y*$y - 4*$x;
      #   next if $z == 0;
      #   next if $z is a perfect square
      # Menezes seems to imply only the q test needs to be done.

      # We perhaps could verify with a BPSW test on the result.  This could:
      #  1) save us from accidently outputing a non-prime due to some mistake
      #  2) make history by finding the first known BPSW pseudo-prime
      # croak "Maurer prime $n failed BPSW" unless is_prob_prime($n);
      #warn "     and passed BPSW.\n";

      return $n;
    }
    no Math::BigFloat;
    no Math::BigInt;
  }
}

sub all_factors {
  my $n = shift;
  my @factors = factor($n);
  my %all_factors;
  foreach my $f1 (@factors) {
    next if $f1 >= $n;
    # We're adding to %all_factors in the loop, so grab the keys now.
    my @all = keys %all_factors;;
    if (!defined $bigint::VERSION) {
      foreach my $f2 (@all) {
        $all_factors{$f1*$f2} = 1 if ($f1*$f2) < $n;
      }
    } else {
      # Many of the factors will be numified after coming back, so we need
      # to make sure we're using bigints when we calculate the product.
      foreach my $f2 (@all) {
        my $product = Math::BigInt->new("$f1") * Math::BigInt->new("$f2");
        $product = int($product->bstr) if $product <= ~0;
        $all_factors{$product} = 1 if $product < $n;
      }
    }
    $all_factors{$f1} = 1;
  }
  @factors = sort {$a<=>$b} keys %all_factors;
  return @factors;
}


# A008683 Moebius function mu(n)
# A030059, A013929, A030229, A002321, A005117, A013929 all relate.

# One can argue for the Omega function (A001221), Euler Phi (A000010), and
# Merten's functions also.

sub moebius {
  my($n) = @_;
  _validate_positive_integer($n, 1);
  return 1 if $n == 1;

  # Quick check for small replicated factors
  return 0 if ($n >= 25) && (!($n % 4) || !($n % 9) || !($n % 25));

  my @factors = factor($n);
  my %all_factors;
  foreach my $factor (@factors) {
    return 0 if $all_factors{$factor}++;
  }
  return (((scalar @factors) % 2) == 0) ? 1 : -1;
}


# Euler Phi, aka Euler Totient.  A000010

sub euler_phi {
  my($n) = @_;
  # SAGE defines this to be 0 for all n <= 0.  Others choose differently.
  return 0 if defined $n && $n <= 0;  # Following SAGE's logic here.
  _validate_positive_integer($n);
  return 1 if $n <= 1;

  my %factor_mult;
  my @factors = grep { !$factor_mult{$_}++ } factor($n);

  # Direct from Euler's product formula.  Note division will be exact.
  #my $totient = $n;
  #foreach my $factor (@factors) {
  #  $totient = int($totient/$factor) * ($factor-1);
  #}

  # Alternate way doing multiplications only.
  if (ref($n) ne 'Math::BigInt') {
    my $totient = 1;  # $n - $n + 1 will make this a bigint if needed
    foreach my $factor (@factors) {
      $totient *= ($factor - 1);
      $totient *= $factor for (2 .. $factor_mult{$factor});
    }
    return $totient;
  }

  # Some real wackiness to solve issues with Math::BigInt::GMP (not seen with
  # Pari or Calc).  Results of the multiply will go negative if we don't do
  # this.  Standalone bug:
  #      perl -E 'my $a = 2931542417; use bigint lib=>'GMP'; my $n = 49754396241690624; my $x = $n*$a; say $x;'
  # This may be related to RT 71548 of Math::BigInt::GMP.
  my $totient = $n->copy->bone;
  foreach my $factor (@factors) {
    my $f = $n->copy->bzero->badd("$factor");
    $totient->bmul($f->copy->bsub(1));
    $totient->bmul($f)  for (2 .. $factor_mult{$factor});
  }
  $totient;
}

# Omega function A001221.  Just an example.
sub _omega {
  my($n) = @_;
  return 0 if defined $n && $n <= 1;
  _validate_positive_integer($n);
  my %factor_mult;
  my @factors = grep { !$factor_mult{$_}++ } factor($n);
  return scalar @factors;
}


#############################################################################
# Front ends to functions.
#
# These will do input validation, then call the appropriate internal function
# based on the input (XS, GMP, PP).
#############################################################################

# Doing a sub here like:
#
#   sub foo {  my($n) = @_;  _validate_positive_integer($n);
#              return _XS_... if $_Config{'xs'} && $n <= $_Config{'maxparam'}; }
#
# takes about 0.7uS on my machine.  Operations like is_prime and factor run
# on small input (under 100_000) typically take a lot less time than this.  So
# the overhead for these is significantly more than just the XS call itself.
#
# The plan for some of these functions will be to invert the operation.  That
# is, the XS functions will look at the input and make a call here if the input
# is large.

sub is_prime {
  my($n) = @_;
  return 0 if $n <= 0;
  _validate_positive_integer($n);

  return _XS_is_prime($n) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::GMP::is_prime($n) if $_HAVE_GMP;
  return is_prob_prime($n);
}

sub next_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  # If n is native precision AND not a bigint or not the last native prime,
  # then we can call the XS function.
  return _XS_next_prime($n) if $n <= $_XS_MAXVAL
                            && (ref($_[0]) ne 'Math::BigInt' || $n < $_Config{'maxprime'});

  if ($_HAVE_GMP) {
    # If $n is a bigint object, try to make the return value the same
    return (ref($_[0]) eq 'Math::BigInt')
        ?  $_[0]->copy->bzero->badd(Math::Prime::Util::GMP::next_prime($n))
        :  Math::Prime::Util::GMP::next_prime($n);
  }
  return Math::Prime::Util::PP::next_prime($n);
}

sub prev_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_prev_prime($n) if $n <= $_XS_MAXVAL;
  if ($_HAVE_GMP) {
    # If $n is a bigint object, try to make the return value the same
    return (ref($n) eq 'Math::BigInt')
        ?  $n->copy->bzero->badd(Math::Prime::Util::GMP::prev_prime($n))
        :  Math::Prime::Util::GMP::prev_prime($n);
  }
  return Math::Prime::Util::PP::prev_prime($n);
}

sub prime_count {
  my($low,$high) = @_;
  if (defined $high) {
    _validate_positive_integer($low);
    _validate_positive_integer($high);
  } else {
    ($low,$high) = (2, $low);
    _validate_positive_integer($high);
  }
  return 0 if $high < 2  ||  $low > $high;

  return _XS_prime_count($low,$high) if $high <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::prime_count($low,$high);
}

sub nth_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_nth_prime($n) if $_Config{'xs'} && $n <= $_Config{'maxprimeidx'};
  return Math::Prime::Util::PP::nth_prime($n);
}

sub factor {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_factor($n) if $n <= $_XS_MAXVAL;

  if ($_HAVE_GMP) {
    my @factors = Math::Prime::Util::GMP::factor($n);
    if (ref($n) eq 'Math::BigInt') {
      @factors = map { ($_ > ~0) ? $n->copy->bzero->badd($_) : $_ } @factors;
    }
    return @factors;
  }

  return Math::Prime::Util::PP::factor($n);
}

sub is_strong_pseudoprime {
  my($n) = shift;
  _validate_positive_integer($n);
  # validate bases?
  return _XS_miller_rabin($n, @_) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::GMP::is_strong_pseudoprime($n, @_) if $_HAVE_GMP;
  return Math::Prime::Util::PP::miller_rabin($n, @_);
}

sub is_strong_lucas_pseudoprime {
  my($n) = shift;
  _validate_positive_integer($n);
  return Math::Prime::Util::GMP::is_strong_lucas_pseudoprime("$n") if $_HAVE_GMP;
  return Math::Prime::Util::PP::is_strong_lucas_pseudoprime($n);
}

sub miller_rabin {
  #warn "miller_rabin() is deprecated. Use is_strong_pseudoprime instead.";
  return is_strong_pseudoprime(@_);
}

#############################################################################

  # Timings for various combinations, given the current possibilities of:
  #    1) XS MR optimized (either x86-64, 32-bit on 64-bit mach, or half-word)
  #    2) XS MR non-optimized (big input not on 64-bit machine)
  #    3) PP MR with small input (non-bigint Perl)
  #    4) PP MR with large input (using functions for mulmod)
  #    5) PP MR with full bigints
  #    6) PP Lucas with small input
  #    7) PP Lucas with large input
  #    8) PP Lucas with full bigints
  #
  # Time for one test:
  #       0.5uS  XS MR with small input
  #       0.8uS  XS MR with large input
  #       7uS    PP MR with small input
  #     400uS    PP MR with large input
  #    5000uS    PP MR with bigint
  #    2700uS    PP LP with small input
  #    6100uS    PP LP with large input
  #    7400uS    PP LP with bigint

sub is_prob_prime {
  my($n) = @_;
  return 0 if defined $n && $n < 2;
  _validate_positive_integer($n);

  return _XS_is_prob_prime($n) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::GMP::is_prob_prime($n) if $_HAVE_GMP;

  return 2 if $n == 2 || $n == 3 || $n == 5 || $n == 7;
  return 0 if $n < 11;
  return 0 if !($n % 2) || !($n % 3) || !($n % 5) || !($n % 7);
  foreach my $i (qw/11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71/) {
    return 2 if $i*$i > $n;   return 0 if !($n % $i);
  }

  if ($n < 105936894253) {   # BPSW seems to be faster after this
    # Deterministic set of Miller-Rabin tests.
    my @bases;
    if    ($n <          9080191) { @bases = (31, 73); }
    elsif ($n <       4759123141) { @bases = (2, 7, 61); }
    elsif ($n <     105936894253) { @bases = (2, 1005905886, 1340600841); }
    elsif ($n <   31858317218647) { @bases = (2, 642735, 553174392, 3046413974); }
    elsif ($n < 3071837692357849) { @bases = (2, 75088, 642735, 203659041, 3613982119); }
    else                          { @bases = (2, 325, 9375, 28178, 450775, 9780504, 1795265022); }
    return Math::Prime::Util::PP::miller_rabin($n, @bases)  ?  2  :  0;
  }

  # BPSW probable prime.  No composites are known to have passed this test
  # since it was published in 1980, though we know infinitely many exist.
  # It has also been verified that no 64-bit composite will return true.
  # Slow since it's all in PP, but it's the Right Thing To Do.

  return 0 unless Math::Prime::Util::PP::miller_rabin($n, 2);
  return 0 unless Math::Prime::Util::PP::is_strong_lucas_pseudoprime($n);
  return ($n <= 18446744073709551615)  ?  2  :  1;
}

#############################################################################

sub prime_count_approx {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  # Turn on high precision FP if they gave us a big number.
  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  #    Method             10^10 %error  10^19 %error
  #    -----------------  ------------  ------------
  #    average bounds      .01%          .0002%
  #    li(n)               .0007%        .00000004%
  #    li(n)-li(n^.5)/2    .0004%        .00000001%
  #    R(n)                .0004%        .00000001%
  #
  # Also consider: http://trac.sagemath.org/sage_trac/ticket/8135

  # return int( (prime_count_upper($x) + prime_count_lower($x)) / 2);

  # return int( LogarithmicIntegral($x) );

  # return int( LogarithmicIntegral($x) - LogarithmicIntegral(sqrt($x))/2 );

  my $result = RiemannR($x) + 0.5;

  return Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);
}

sub prime_count_lower {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  my $flogx = log($x);

  # Chebyshev:            1*x/logx       x >= 17
  # Rosser & Schoenfeld:  x/(logx-1/2)   x >= 67
  # Dusart 1999:          x/logx*(1+1/logx+1.8/logxlogx)  x >= 32299
  # Dusart 2010:          x/logx*(1+1/logx+2.0/logxlogx)  x >= 88783

  # The Dusart (1999 or 2010) bounds are far, far better than the others.

  # TODO:
  #   We need a assume_riemann_hypothesis(bool) function, which would let
  #   these bounds return the Schoenfeld or Stoll limits.  The former are
  #   better for n > ~10^12, the latter for n > ~10^8.
  #   Given the ability to hand test to ~100_000M, if the Stoll limits are
  #   better then we can always use them up to the verification point.

  # For smaller numbers this works out well.
  return int( $x / ($flogx - 0.7) ) if $x < 599;

  my $a;
  # Hand tuned for small numbers (< 60_000M)
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
  else                    { $a = 2.00; } # Dusart 2010, page 2

  my $result = ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx));
  $result = Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);
}

sub prime_count_upper {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  # Chebyshev:            1.25506*x/logx       x >= 17
  # Rosser & Schoenfeld:  x/(logx-3/2)         x >= 67
  # Dusart 1999:          x/logx*(1+1/logx+2.51/logxlogx)   x >= 355991
  # Dusart 2010:          x/logx*(1+1/logx+2.334/logxlogx)  x >= 2_953_652_287

  # As with the lower bounds, Dusart bounds are best by far.

  # Another possibility here for numbers under 3000M is to use Li(x)
  # minus a correction.

  my $flogx = log($x);

  # These work out well for small values
  return int( ($x / ($flogx - 1.048)) + 1.0 ) if $x <  1621;
  return int( ($x / ($flogx - 1.071)) + 1.0 ) if $x <  5000;
  return int( ($x / ($flogx - 1.098)) + 1.0 ) if $x < 15900;

  my $a;
  # Hand tuned for small numbers (< 60_000M)
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
  elsif ($x < 2953652287) { $a = 2.362; }
  else                    { $a = 2.334; } # Dusart 2010, page 2
  #elsif ($x <60000000000) { $a = 2.362; }
  #else                    { $a = 2.51;  } # Dusart 1999, page 14

  # Old versions of Math::BigFloat will do the Wrong Thing with this.
  #return int( ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) + 1.0 );
  my $result = ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) + 1.0;
  return Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);

}

#############################################################################

sub nth_prime_approx {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);

  # Cipolla 1902:
  #    m=0   fn * ( flogn + flog2n - 1 );
  #    m=1   + ((flog2n - 2)/flogn) );
  #    m=2   - (((flog2n*flog2n) - 6*flog2n + 11) / (2*flogn*flogn))
  #    + O((flog2n/flogn)^3)
  #
  # Shown in Dusart 1999 page 12, as well as other sources such as:
  #   http://www.emis.de/journals/JIPAM/images/153_02_JIPAM/153_02.pdf
  # where the main issue you run into is that you're doing polynomial
  # interpolation, so it oscillates like crazy with many high-order terms.
  # Hence I'm leaving it at m=2.
  #

  my $approx = $n * ( $flogn + $flog2n - 1
                      + (($flog2n - 2)/$flogn)
                      - ((($flog2n*$flog2n) - 6*$flog2n + 11) / (2*$flogn*$flogn))
                    );

  # Apply a correction to help keep values close.
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
  # $approx = -0.025 is better for the last, but it gives problems with some
  # other code that always wants the asymptotic approximation to be >= actual.

  if ( ($approx >= ~0) && (ref($approx) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_approx($n) overflow";
  }

  return int($approx + 0.5);
}

# The nth prime will be greater than or equal to this number
sub nth_prime_lower {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);  # Note distinction between log_2(n) and log^2(n)

  # Dusart 1999 page 14, for all n >= 2
  #my $lower = $n * ($flogn + $flog2n - 1.0 + (($flog2n-2.25)/$flogn));
  # Dusart 2010 page 2, for all n >= 3
  my $lower = $n * ($flogn + $flog2n - 1.0 + (($flog2n-2.10)/$flogn));

  if ( ($lower >= ~0) && (ref($lower) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_lower($n) overflow";
  }

  return int($lower);
}

# The nth prime will be less or equal to this number
sub nth_prime_upper {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);  # Note distinction between log_2(n) and log^2(n)

  my $upper;
  if      ($n >= 688383) {   # Dusart 2010 page 2
    $upper = $n * ( $flogn  +  $flog2n - 1.0 + (($flog2n-2.00)/$flogn) );
  } elsif ($n >= 178974) {   # Dusart 2010 page 7
    $upper = $n * ( $flogn  +  $flog2n - 1.0 + (($flog2n-1.95)/$flogn) );
  } elsif ($n >=  39017) {   # Dusart 1999 page 14
    $upper = $n * ( $flogn  +  $flog2n - 0.9484 );
  } elsif ($n >=      6) {   # Modified Robin 1983, for 6-39016 only
    $upper = $n * ( $flogn  +  0.6000 * $flog2n );
  } else {
    $upper = $n * ( $flogn  +  $flog2n );
  }

  if ( ($upper >= ~0) && (ref($upper) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_upper($n) overflow";
  }

  return int($upper + 1.0);
}


#############################################################################


#############################################################################

sub RiemannR {
  my($n) = @_;
  croak("Invalid input to ReimannR:  x must be > 0") if $n <= 0;

  return Math::Prime::Util::PP::RiemannR($n, 1e-30) if defined $bignum::VERSION || ref($n) eq 'Math::BigFloat';
  return Math::Prime::Util::PP::RiemannR($n) if !$_Config{'xs'};
  return _XS_RiemannR($n);

  # We could make a new object, like:
  #    require Math::BigFloat;
  #    my $bign = new Math::BigFloat "$n";
  #    my $result = Math::Prime::Util::PP::RiemannR($bign);
  #    return $result;
}

sub ExponentialIntegral {
  my($n) = @_;
  croak "Invalid input to ExponentialIntegral:  x must be != 0" if $n == 0;

  return Math::Prime::Util::PP::ExponentialIntegral($n, 1e-30) if defined $bignum::VERSION || ref($n) eq 'Math::BigFloat';
  return Math::Prime::Util::PP::ExponentialIntegral($n) if !$_Config{'xs'};
  return _XS_ExponentialIntegral($n);
}

sub LogarithmicIntegral {
  my($n) = @_;
  return 0 if $n == 0;
  croak("Invalid input to LogarithmicIntegral:  x must be >= 0") if $n <= 0;

  if ( defined $bignum::VERSION || ref($n) eq 'Math::BigFloat' ) {
    return Math::BigFloat->binf('-') if $n == 1;
    return Math::BigFloat->new('1.045163780117492784844588889194613136522615578151201575832909144075013205210359530172717405626383356306') if $n == 2;
  } else {
    if ($n == 1) {
      my $neg_infinity = 0+'-inf';
      return (-9)**9**9 if $neg_infinity == 0;
      return $neg_infinity;
    }
    return 1.045163780117492784844588889194613136522615578151 if $n == 2;
  }
  ExponentialIntegral(log($n));
}

#############################################################################

use Math::Prime::Util::MemFree;

1;

__END__


# ABSTRACT: Utilities related to prime numbers, including fast generators / sievers

=pod

=encoding utf8


=head1 NAME

Math::Prime::Util - Utilities related to prime numbers, including fast sieves and factoring


=head1 VERSION

Version 0.10


=head1 SYNOPSIS

  # Normally you would just import the functions you are using.
  # Nothing is exported by default.  List the functions, or use :all.
  use Math::Prime::Util ':all';


  # Get a big array reference of many primes
  my $aref = primes( 100_000_000 );

  # All the primes between 5k and 10k inclusive
  my $aref = primes( 5_000, 10_000 );

  # If you want them in an array instead
  my @primes = @{primes( 500 )};


  # For non-bigints, is_prime and is_prob_prime will always be 0 or 2.
  # They return return 0 (composite), 2 (prime), or 1 (probably prime)
  say "$n is prime"  if is_prime($n);
  say "$n is ", (qw(composite maybe_prime? prime))[is_prob_prime($n)];

  # Strong pseudoprime test with multiple bases, using Miller-Rabin
  say "$n is a prime or 2/7/61-psp" if is_strong_pseudoprime($n, 2, 7, 61);

  # Strong Lucas-Selfridge test
  say "$n is a prime or slpsp" if is_strong_lucas_pseudoprime($n);

  # step to the next prime (returns 0 if not using bigints and we'd overflow)
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

  # Get all factors
  @divisors = all_factors( $n );

  # Euler phi (aka the totient) on a large number
  use bigint;  say euler_phi( 801294088771394680000412 );

  # Moebius function used to calculate Mertens
  $sum += moebius($_) for (1..200); say "Mertens(200) = $sum";

  # Ei, li, and Riemann R functions
  my $ei = ExponentialIntegral($x);    # $x a real: $x != 0
  my $li = LogarithmicIntegral($x);    # $x a real: $x >= 0
  my $R  = RiemannR($x)                # $x a real: $x > 0


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
  my $rand_prime = random_nbit_prime(128);   # random 128-bit prime
  my $rand_prime = random_maurer_prime(256); # random 256-bit provable prime


=head1 DESCRIPTION

A set of utilities related to prime numbers.  These include multiple sieving
methods, is_prime, prime_count, nth_prime, approximations and bounds for
the prime_count and nth prime, next_prime and prev_prime, factoring utilities,
and more.

The default sieving and factoring are intended to be (and currently are)
the fastest on CPAN, including L<Math::Prime::XS>, L<Math::Prime::FastSieve>,
L<Math::Factor::XS>, L<Math::Prime::TiedArray>, L<Math::Big::Factors>, and
L<Math::Primality> (when the GMP module is available).  For numbers in the
10-20 digit range, it is often orders of magnitude faster.  Typically it is
faster than L<Math::Pari> for 64-bit operations, with the exception of
factoring 16+ digit semiprimes.

The main development of the module has been for working with Perl UVs, so
32-bit or 64-bit.  Bignum support is still experimental.  One advantage is
that it requires no external software (e.g. GMP or Pari).  For much faster
performance for bigints, install the L<Math::Prime::Util::GMP> module.  If
you're doing a lot of big number operations, look into L<Math::GMPz> and
L<Math::Pari> as well.

The module is thread-safe and allows concurrency between Perl threads while
still sharing a prime cache.  It is not itself multithreaded.  See the
L<Limitations|/"LIMITATIONS"> section if you are using Win32 and threads in
your program.


=head1 BIGNUM SUPPORT

By default all functions support bigints.  The module will not turn on bigint
support for you -- you will need to C<use bigint>, C<use bignum>, or pass in
a L<Math::BigInt> object as your input.  The functions take some care to
perform all bignum operations using the same class as was passed in, allowing
the module to work properly with Calc, FastCalc, GMP, Pari, etc.  You should
try to install L<Math::Prime::Util::GMP> if you plan to use bigints with this
module, as it will make it run much faster.


Some of the functions, notably:

  factor
  is_prime
  is_prob_prime
  is_strong_pseudoprime
  next_prime
  prev_prime
  prime_count
  nth_prime

work very fast (under 1 microsecond) on small inputs, but the wrappers for
input validation and bigint support take more time than the function itself.
Using the flag '-bigint', e.g.:

  use Math::Prime::Util qw(-bigint);

will turn off bigint support for those functions.  Those functions will then
go directly to the XS versions, which will speed up very small inputs a B<lot>.
This is useful if you're using the functions in a loop, but since the difference
is less than a millisecond, it's really not important in general (also, a
future implementation may find a way to speed this up without the option).


If you are using bigints, there are two performance suggestions.  The first
is to install L<Math::Prime::Util::GMP>, as that will vastly increase the speed
for many of the functions.  This does require the L<GMP|gttp://gmplib.org>
library be installed on your system, but this increasingly comes pre-installed
or easily available using the OS vendor package installation tool.  If you
do not want to use that, I recommend L<Math::BigInt::GMP> or
L<Math::BigInt::Pari> and then writing C<use bigint try => 'GMP,Pari'>.
Large modular exponentiation is much faster using the GMP or Pari backends.
This is not so important if you installed L<Math::Prime::Util::GMP>, but it can
still speed up large random Maurer primes.


Having run these functions on many versions of Perl, if you're using anything
older than Perl 5.14, I would recommend you upgrade if you are using bignums
a lot.  There are some brittle behaviors on 5.12.4 and earlier with bignums.


=head1 FUNCTIONS

=head2 is_prime

  print "$n is prime" if is_prime($n);

Returns 2 if the number is prime, 0 if not.  For numbers larger than C<2^64>
it will return 0 for composite and 1 for probably prime, using a strong BPSW
test.  Also note there are probabilistic prime testing functions available.


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

Returns the next prime greater than the input number.  If the input is not a
bigint, then 0 is returned if the next prime is larger than a native integer
type (the last representable primes being C<4,294,967,291> in 32-bit Perl and
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

The current implementation relies on sieving to find the primes within the
interval, so will take some time and memory.  It uses a segmented sieve so
is very memory efficient, and also allows fast results even with large
base values.  The complexity for C<prime_count(a, b)> is approximately
C<O(sqrt(a) + (b-a))>, where the first term is typically negligible below
C<~ 10^11>.  Memory use is proportional only to C<sqrt(a)>, with total
memory use under 1MB for any base under C<10^14>.

A later implementation may work on improving performance for values, both
in reducing memory use (the current maximum is 140MB at C<2^64>) and improving
speed.  Possibilities include a hybrid table approach, using an explicit
formula with C<li(x)> or C<R(x)>, or one of the Meissel, Lehmer,
or Lagarias-Miller-Odlyzko-Deleglise-Rivat methods.  For any use with inputs
over 1,000 million or so, think about whether an approximation or bounds would
work, as they will be much faster.


=head2 prime_count_upper

=head2 prime_count_lower

  my $lower_limit = prime_count_lower($n);
  my $upper_limit = prime_count_upper($n);
  #   $lower_limit  <=  prime_count(n)  <=  $upper_limit

Returns an upper or lower bound on the number of primes below the input number.
These are analytical routines, so will take a fixed amount of time and no
memory.  The actual C<prime_count> will always be equal to or between these
numbers.

A common place these would be used is sizing an array to hold the first C<$n>
primes.  It may be desirable to use a bit more memory than is necessary, to
avoid calling C<prime_count>.

These routines use verified tight limits below a range at least C<2^35>, and
use the Dusart (2010) bounds of

    x/logx * (1 + 1/logx + 2.000/log^2x) <= Pi(x)

    x/logx * (1 + 1/logx + 2.334/log^2x) >= Pi(x)

above that range.  These bounds do not assume the Riemann Hypothesis.


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
large inputs.  A segmented sieve is used for large inputs, so it is memory
efficient.  On my machine it will return the 203,280,221st prime (the largest
that fits in 32-bits) in 2.5 seconds.  The 10^9th prime takes 15 seconds to
find, while the 10^10th prime takes nearly four minutes.  As with prime_count,
think carefully about whether a bound or an approximation would be acceptable.

If the bigint or bignum module is not in use, this will generate an overflow
exception if the number requested would result in a prime that cannot fit in
a native type.  If bigints are in use, then the calculation will proceed,
though it will be exceedingly slow.  A later version of
L<Math::Prime::Util::GMP> may include this functionality which would help for
32-bit machines.


=head2 nth_prime_upper

=head2 nth_prime_lower

  my $lower_limit = nth_prime_lower($n);
  my $upper_limit = nth_prime_upper($n);
  #   $lower_limit  <=  nth_prime(n)  <=  $upper_limit

Returns an analytical upper or lower bound on the Nth prime.  These are very
fast as they do not need to sieve or search through primes or tables.  An
exact answer is returned for tiny values of C<n>.  The lower limit uses the
Dusart 2010 bound for all C<n>, while the upper bound uses one of the two
Dusart 2010 bounds for C<n E<gt>= 178974>, a Dusart 1999 bound for
C<n E<gt>= 39017>, and a simple bound of C<n * (logn + 0.6 * loglogn)>
for small C<n>.


=head2 nth_prime_approx

  say "The one trillionth prime is ~ ", nth_prime_approx(10**12);

Returns an approximation to the C<nth_prime> function, without having to
generate any primes.  Uses the Cipolla 1902 approximation with two
polynomials, plus a correction for small values to reduce the error.


=head2 is_strong_pseudoprime

  my $maybe_prime = is_strong_pseudoprime($n, 2);
  my $probably_prime = is_strong_pseudoprime($n, 2, 3, 5, 7, 11, 13, 17);

Takes a positive number as input and one or more bases.  The bases must be
greater than C<1>.  Returns 1 if the input is a prime or a strong
pseudoprime to all of the bases, and 0 if not.

If 0 is returned, then the number really is a composite.  If 1 is returned,
then it is either a prime or a strong pseudoprime to all the given bases.
Given enough distinct bases, the chances become very, very strong that the
number is actually prime.

This is usually used in combination with other tests to make either stronger
tests (e.g. the strong BPSW test) or deterministic results for numbers less
than some verified limit (e.g. it has long been known that no more than three
selected bases are required to give correct primality test results for any
32-bit number).  Given the small chances of passing multiple bases, there
are some math packages that just use multiple MR tests for primality testing.

Even numbers other than 2 will always return 0 (composite).  While the
algorithm does run with even input, most sources define it only on odd input.
Returning composite for all non-2 even input makes the function match most
other implementations including L<Math::Primality>'s C<is_strong_pseudoprime>
function.

=head2 miller_rabin

An alias for C<is_strong_pseudoprime>.  This name is being deprecated.


=head2 is_strong_lucas_pseudoprime

Takes a positive number as input, and returns 1 if the input is a strong
Lucas pseudoprime using the Selfridge method of choosing D, P, and Q (some
sources call this a strong Lucas-Selfridge pseudoprime).  This is one half
of the BPSW primality test (the Miller-Rabin strong pseudoprime test with
base 2 being the other half).


=head2 is_prob_prime

  my $prob_prime = is_prob_prime($n);
  # Returns 0 (composite), 2 (prime), or 1 (probably prime)

Takes a positive number as input and returns back either 0 (composite),
2 (definitely prime), or 1 (probably prime).

For 64-bit input (native or bignum), this uses a tuned set of Miller-Rabin
tests such that the result will be deterministic.  Either 2, 3, 4, 5, or 7
Miller-Rabin tests are performed (no more than 3 for 32-bit input), and the
result will then always be 0 (composite) or 2 (prime).  A later implementation
may change the internals, but the results will be identical.

For inputs larger than C<2^64>, a strong Baillie-PSW primality test is
performed (aka BPSW or BSW).  This is a probabilistic test, so only
0 (composite) and 1 (probably prime) are returned.  There is a possibility that
composites may be returned marked prime, but since the test was published in
1980, not a single BPSW pseudoprime has been found, so it is extremely likely
to be prime.
While we believe (Pomerance 1984) that an infinite number of counterexamples
exist, there is a weak conjecture (Martin) that none exist under 10000 digits.


=head2 moebius

  say "$n is square free" if moebius($n) != 0;
  $sum += moebius($_) for (1..200); say "Mertens(200) = $sum";

Returns the Möbius function (also called the Moebius, Mobius, or MoebiusMu
function) for a positive non-zero integer input.  This function is 1 if
C<n = 1>, 0 if C<n> is not square free (i.e. C<n> has a repeated factor),
and C<-1^t> if C<n> is a product of C<t> distinct primes.  This is an
important function in prime number theory.


=head2 euler_phi

  say "The Euler totient of $n is ", euler_phi($n);

Returns the Euler totient function (also called Euler's phi or phi function)
for an integer value.  This is an arithmetic function that counts the number
of positive integers less than or equal to C<n> that are relatively prime to
C<n>.  Given the definition used, C<euler_phi> will return 0 for all
C<n E<lt> 1>.  This follows the logic used by SAGE.  Mathematic/WolframAlpha
also returns 0 for input 0, but returns C<euler_phi(-n)> for C<n E<lt> 0>.



=head2 random_prime

  my $small_prime = random_prime(1000);      # random prime <= limit
  my $rand_prime = random_prime(100, 10000); # random prime within a range

Returns a psuedo-randomly selected prime that will be greater than or equal
to the lower limit and less than or equal to the upper limit.  If no lower
limit is given, 2 is implied.  Returns undef if no primes exist within the
range.  The L<rand> function is called one or more times for selection.

The goal is to return a uniform distribution of the primes in the range,
meaning for each prime in the range, the chances are equally likely that it
will be seen.

The current algorithm does a random index selection for small numbers, which
is deterministic.  For larger numbers, this slows down, so for 32-bit ranges,
the obvious Monte Carlo method is used, where random numbers in the range are
selected until one is prime.  For even larger ranges, a method similar to that
of Fouque and Tibouchi (2011) algorithm A1 is used.

Perl's L<rand> function is normally called, but if the sub C<main::rand>
exists, it will be used instead.  When called with no arguments it should
return a float value between 0 and 1-epsilon, with 31 bits of randomness.
Examples:

  # Use Mersenne Twister
  use Math::Random::MT::Auto qw/rand/;

  # Use a custom random function
  sub rand { ... }

If you want cryptographically secure primes, at minimum a better source of
random numbers should be used, e.g. L<Crypt::Random>.  Until this module
has more testing, I would point the user to L<Crypt::Primes> for production
use.


=head2 random_ndigit_prime

  say "My 4-digit prime number is: ", random_ndigit_prime(4);

Selects a random n-digit prime, where the input is an integer number of
digits between 1 and the maximum native type (10 for 32-bit, 20 for 64-bit,
10000 if bigint is active).  One of the primes within that range
(e.g. 1000 - 9999 for 4-digits) will be uniformly selected using the
L<rand> function as described above.


=head2 random_nbit_prime

  use bigint;  my $bigprime = random_nbit_prime(512);

Selects a random n-bit prime, where the input is an integer number of bits
between 2 and the maximum representable bits (32, 64, or 100000 for native
32-bit, native 64-bit, and bigint respectively).  A prime with the nth bit
set will be uniformly selected, with randomness supplied via calls to the
L<rand> function as described above.

Since this uses the random_prime function, all uniformity properties of that
function apply to this.  The n-bit range is partitioned into nearly equal
segments less than C<2^31>, a segment is randomly selected, then the trivial
Monte Carlo algorithm is used to select a prime from within the segment.
This gives a nearly uniform distribution, doesn't use excessive random source,
and can be very fast.  When used with bigints, having the
L<Math::Prime::Util::GMP> module installed will make it run much faster.


=head2 random_maurer_prime

  use bigint;  my $bigprime = random_maurer_prime(512);

Construct an n-bit provable prime, using the algorithm of Ueli Maurer (1995).
This is the same algorithm used by L<Crypt::Primes>.

The differences between this function and that in L<Crypt::Primes> include
(1) the current version of C::P has been in use for 9 years, while M::P::U
is new and relatively untested;
(2) no external libraries are needed for this module, while C::P requires
L<Math::Pari>;
(3) C::P is quite fast for all sizes -- M::P::U is really
fast for native bit sizes, so-so for large bit sizes when
L<Math::Prime::Util::GMP> is installed, but ridiculously slow when using
native Perl bigints for large bit sizes;
(4) C::P uses a modified version of final acceptance criteria
(C<q E<lt> n**(1/3)> without the rest of Lemma 2), while this module uses the
original set;
(5) C::P  has some useful options for cryptography;
(6) C::P is hardcoded to use L<Crypt::Random>, while this function will use
whatever you set C<rand> to (this is more flexible but also prone to misuse).

Any feedback on this function would be greatly appreciated.





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

=head2 prime_get_config

  my $cached_up_to = prime_get_config->{'precalc_to'};

Returns a reference to a hash of the current settings.  The hash is copy of
the configuration, so changing it has no effect.  The settings include:

  precalc_to      primes up to this number are calculated
  maxbits         the maximum number of bits for native operations
  xs              0 or 1, indicating the XS code is available
  gmp             0 or 1, indicating GMP code is available
  maxparam        the largest value for most functions, without bigint
  maxdigits       the max digits in a number, without bigint
  maxprime        the largest representable prime, without bigint
  maxprimeidx     the index of maxprime, without bigint



=head1 FACTORING FUNCTIONS

=head2 factor

  my @factors = factor(3_369_738_766_071_892_021);
  # returns (204518747,16476429743)

Produces the prime factors of a positive number input, in numerical order.
The special cases of C<n = 0> and C<n = 1> will return C<n>, which
guarantees multiplying the factors together will always result in the
input value, though those are the only cases where the returned factors
are not prime.

The current algorithm for non-bigints is a sequence of small trial division,
a few rounds of Pollard's Rho, SQUFOF, Hart's one line factorization, a long
run of Pollard's Rho, and finally trial division if anything survives.  This
process is repeated for each non-prime factor.  In practice, it is very rare
to require more than the first Rho + SQUFOF to find a factor.

Factoring bigints works with pure Perl, and can be very handy on 32-bit
machines for numbers just over the 32-bit limit, but it can be B<very> slow
for "hard" numbers.  Installing the L<Math::Prime::Util::GMP> module will speed
up bigint factoring a B<lot>, and all future effort on large number factoring
will be in that module.  If you do not have that module for some reason, use
the GMP or Pari version of bigint if possible
(e.g. C<use bigint try => 'GMP,Pari'>), which will run 2-3x faster (though
still 100x slower than the real GMP code).


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

Accuracy should be at least 14 digits.  The current implementation isn't
correctly storing constants as big floats, so is not giving increased accuracy
with big numbers like it should.


=head1 EXAMPLES

Print pseudoprimes base 17:

    perl -MMath::Prime::Util=:all -E 'my $n=$base|1; while(1) { print "$n " if is_strong_pseudoprime($n,$base) && !is_prime($n); $n+=2; } BEGIN {$|=1; $base=17}'

Print some primes above 64-bit range:

    perl -MMath::Prime::Util=:all -Mbigint -E 'my $start=100000000000000000000; say join "\n", @{primes($start,$start+1000)}'
    # Similar code using Pari:
    # perl -MMath::Pari=:int,PARI,nextprime -E 'my $start = PARI "100000000000000000000"; my $end = $start+1000; my $p=nextprime($start); while ($p <= $end) { say $p; $p = nextprime($p+1); }'


=head1 LIMITATIONS

I have not completed testing all the functions near the word size limit
(e.g. C<2^32> for 32-bit machines).  Please report any problems you find.

Perl versions earlier than 5.8.0 have issues with 64-bit that show up in the
factoring tests.  The test suite will try to determine if your Perl is broken.
If you use later versions of Perl, or Perl 5.6.2 32-bit, or Perl 5.6.2 64-bit
and keep numbers below C<~ 2^52>, then everything works.  The best solution is
to update to a more recent Perl.

The module is thread-safe and should allow good concurrency on all platforms
that support Perl threads except Win32 (Cygwin works).  With Win32, either
don't use threads or make sure C<prime_precalc> is called before using
C<primes>, C<prime_count>, or C<nth_prime> with large inputs.  This is B<only>
an issue if you use non-Cygwin Win32 and call these routines from within
Perl threads.



=head1 PERFORMANCE

Counting the primes to C<10^10> (10 billion), with time in seconds.
Pi(10^10) = 455,052,511.

   External C programs in C / C++:

       1.9  primesieve 3.6 forced to use only a single thread
       2.2  yafu 1.31
       3.8  primegen (optimized Sieve of Atkin, conf-word 8192)
       5.6  Tomás Oliveira e Silva's unoptimized segmented sieve v2 (Sep 2010)
       6.7  Achim Flammenkamp's prime_sieve (32k segments)
       9.3  http://tverniquet.com/prime/ (mod 2310, single thread)
      11.2  Tomás Oliveira e Silva's unoptimized segmented sieve v1 (May 2003)
      17.0  Pari 2.3.5 (primepi)

   Small portable functions suitable for plugging into XS:

       5.3  My segmented SoE used in this module
      15.6  My Sieve of Eratosthenes using a mod-30 wheel
      17.2  A slightly modified verion of Terje Mathisen's mod-30 sieve
      35.5  Basic Sieve of Eratosthenes on odd numbers
      33.4  Sieve of Atkin, from Praxis (not correct)
      72.8  Sieve of Atkin, 10-minute fixup of basic algorithm
      91.6  Sieve of Atkin, Wikipedia-like

Perl modules, counting the primes to C<800_000_000> (800 million), in seconds:

  Time (s)   Module                      Version  Notes
  ---------  --------------------------  -------  -----------
       0.36  Math::Prime::Util           0.09     segmented mod-30 sieve
       0.9   Math::Prime::Util           0.01     mod-30 sieve
       2.9   Math::Prime::FastSieve      0.12     decent odd-number sieve
      11.7   Math::Prime::XS             0.29     "" but needs a count API
      15.0   Bit::Vector                 7.2
      59.1   Math::Prime::Util::PP       0.09     Perl (fastest I know of)
     170.0   Faster Perl sieve (net)     2012-01  array of odds
     548.1   RosettaCode sieve (net)     2012-06  simplistic Perl
  ~11000     Math::Primality             0.04     Perl + Math::GMPz
  >20000     Math::Big                   1.12     Perl, > 26GB RAM used



C<is_prime>: my impressions:

   Module                    Small inputs   Large inputs (10-20dig)
   -----------------------   -------------  ----------------------
   Math::Prime::Util         Very fast      Pretty fast
   Math::Prime::XS           Very fast      Very, very slow if no small factors
   Math::Pari                Slow           OK
   Math::Prime::FastSieve    Very fast      N/A (too much memory)
   Math::Primality           Very slow      Very slow

The differences are in the implementations:

=over 4

=item L<Math::Prime::FastSieve> only works in a sieved range, which is really
     fast if you can do it (M::P::U will do the same if you call
     C<prime_precalc>).  Larger inputs just need too much time and memory
     for the sieve.

=item L<Math::Primality> uses GMP for all work.  Under ~32-bits it uses 2 or 3
     MR tests, while above 4759123141 it performs a BPSW test.  This is is
     fantastic for bigints over 2^64, but it is significantly slower than
     native precision tests.  With 64-bit numbers it is generally an order of
     magnitude or more slower than any of the others.  Once bigints are being
     used, its performance is quite good.  It is an order of magnitude or more
     faster than this module by default, but installing the
     L<Math::Prime::Util::GMP> module makes this code run slightly faster.

=item L<Math::Pari> has some very effective code, but it has some overhead to
     get to it from Perl.  That means for small numbers it is relatively slow:
     an order of magnitude slower than M::P::XS and M::P::Util (though arguably
     this is only important for benchmarking since "slow" is ~2 microseconds).
     Large numbers transition over to smarter tests so don't slow down much.

=item L<Math::Prime::XS> does trial divisions, which is wonderful if the input
     has a small factor (or is small itself).  But it can take 1000x longer
     if given a large prime.

=item L<Math::Prime::Util> looks in the sieve for a fast bit lookup if that
     exists (default up to 30,000 but it can be expanded, e.g.
     C<prime_precalc>), uses trial division for numbers higher than this but
     not too large (0.1M on 64-bit machines, 100M on 32-bit machines), a
     deterministic set of Miller-Rabin tests for 64-bit and smaller numbers,
     and a BPSW test for bigints.

=back


Factoring performance depends on the input, and the algorithm choices used
are still being tuned.  L<Math::Factor::XS> is very fast when given input with
only small factors, but it slows down rapidly as the smallest factor increases
in size.  For numbers larger than 32 bits, L<Math::Prime::Util> can be 100x or
more faster (a number with only very small factors will be nearly identical,
while a semiprime with large factors will be the extreme end).  L<Math::Pari>'s
underlying algorithms and code are much more mature than this module, and
for 20+ digit numbers will be typically be a better choice.
Small numbers factor much, much faster with Math::Prime::Util.
Pari passes M::P::U in speed somewhere in the 16 digit range and rapidly
increases its lead.  Without the L<Math::Prime::Util::GMP> module, almost
all actions on numbers greater than native scalars will be much faster in Pari.

The presentation here:
 L<http://math.boisestate.edu/~liljanab/BOISECRYPTFall09/Jacobsen.pdf>
has a lot of data on 64-bit and GMP factoring performance I collected in 2009.
Assuming you do not know anything about the inputs, trial division and
optimized Fermat or Lehmen work very well for small numbers (<= 10 digits),
while native SQUFOF is typically the method of choice for 11-18 digits (I've
seen claims that a lightweight QS can be faster for 15+ digits).  Some form
of Quadratic Sieve is usually used for inputs in the 19-100 digit range, and
beyond that is the General Number Field Sieve.  For serious factoring,
I recommend looking at
L<yafu|http://sourceforge.net/projects/yafu/>,
L<msieve|http://sourceforge.net/projects/msieve/>,
L<gmp-ecm|http://ecm.gforge.inria.fr/>,
L<GGNFS|http://sourceforge.net/projects/ggnfs/>,
and L<Pari|http://pari.math.u-bordeaux.fr/>.



=head1 AUTHORS

Dana Jacobsen E<lt>dana@acm.orgE<gt>


=head1 ACKNOWLEDGEMENTS

Eratosthenes of Cyrene provided the elegant and simple algorithm for finding
the primes.

Terje Mathisen, A.R. Quesada, and B. Van Pelt all had useful ideas which I
used in my wheel sieve.

Tomás Oliveira e Silva has released the source for a very fast segmented sieve.
The current implementation does not use these ideas, but future versions likely
will.

The SQUFOF implementation being used is my modifications to Ben Buhrow's
modifications to Bob Silverman's code.  I may experiment with some other
implementations (Ben Buhrows and Jason Papadopoulos both have published
excellent versions in the public domain).


=head1 REFERENCES

=over 4

=item Pierre Dusart, "Estimates of Some Functions Over Primes without R.H.", preprint, 2010.  L<http://arxiv.org/abs/1002.0442/>

=item Pierre Dusart, "Autour de la fonction qui compte le nombre de nombres premiers", PhD thesis, 1998.  In French, but the mathematics is readable and highly recommended reading if you're interesting in prime number bounds.  L<http://www.unilim.fr/laco/theses/1998/T1998_01.html>

=item Gabriel Mincu, "An Asymptotic Expansion", Journal of Inequalities in Pure and Applied Mathematics, v4, n2, 2003.  A very readable account of Cipolla's 1902 nth prime approximation.  L<http://www.emis.de/journals/JIPAM/images/153_02_JIPAM/153_02.pdf>

=item David M. Smith, "Multiple-Precision Exponential Integral and Related Functions".

=item Vincent Pegoraro and Philipp Slusallek, "On the Evaluation of the Complex-Valued Exponential Integral".

=item William H. Press et al., "Numerical Recipes", 3rd edition.

=item W. J. Cody and Henry C. Thacher, Jr., "Rational Chevyshev Approximations for the Exponential Integral E_1(x)".

=item Ueli M. Maurer, "Fast Generation of Prime Numbers and Secure Public-Key Cryptographic Parameters", 1995.  L<http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.26.2151>

=item Pierre-Alain Fouque and Mehdi Tibouchi, "Close to Uniform Prime Number Generation With Fewer Random Bits", 2011.  L<http://eprint.iacr.org/2011/481>

=back


=head1 COPYRIGHT

Copyright 2011-2012 by Dana Jacobsen E<lt>dana@acm.orgE<gt>

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
