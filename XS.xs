
#define PERL_NO_GET_CONTEXT 1 /* Define at top for more efficiency. */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "multicall.h"  /* only works in 5.6 and newer */

#define NEED_newCONSTSUB
#define NEED_newRV_noinc
#define NEED_sv_2pv_flags
#include "ppport.h"

#include "ptypes.h"
#include "cache.h"
#include "sieve.h"
#define FUNC_gcd_ui 1
#include "util.h"
#include "primality.h"
#include "factor.h"
#include "lehmer.h"
#include "lmo.h"
#include "aks.h"
#include "constants.h"

#if BITS_PER_WORD == 64
  #if defined(_MSC_VER)
    #include <stdlib.h>
    #define strtoull _strtoui64
    #define strtoll  _strtoi64
  #endif
  #define PSTRTOULL(str, end, base) strtoull (str, end, base)
  #define PSTRTOLL(str, end, base)  strtoll (str, end, base)
#else
  #define PSTRTOULL(str, end, base) strtoul (str, end, base)
  #define PSTRTOLL(str, end, base)  strtol (str, end, base)
#endif
#if defined(_MSC_VER) && !defined(strtold)
  #define strtold strtod
#endif

#if PERL_REVISION <= 5 && PERL_VERSION <= 6 && BITS_PER_WORD == 64
 /* Workaround perl 5.6 UVs and bigints */
 #define my_svuv(sv)  PSTRTOULL(SvPV_nolen(sv), NULL, 10)
 #define my_sviv(sv)  PSTRTOLL(SvPV_nolen(sv), NULL, 10)
#elif PERL_REVISION <= 5 && PERL_VERSION < 14 && BITS_PER_WORD == 64
 /* Workaround RT 49569 in Math::BigInt::FastCalc (pre 5.14.0) */
 #define my_svuv(sv) ( (!SvROK(sv)) ? SvUV(sv) : PSTRTOULL(SvPV_nolen(sv),NULL,10) )
 #define my_sviv(sv) ( (!SvROK(sv)) ? SvIV(sv) : PSTRTOLL(SvPV_nolen(sv),NULL,10) )
#else
 #define my_svuv(sv) SvUV(sv)
 #define my_sviv(sv) SvIV(sv)
#endif

/* multicall compatibility stuff */
#if (PERL_REVISION <= 5 && PERL_VERSION < 7) || !defined(dMULTICALL)
# define USE_MULTICALL 0   /* Too much trouble to work around it */
#else
# define USE_MULTICALL 1
#endif
#if PERL_VERSION < 13 || (PERL_VERSION == 13 && PERL_SUBVERSION < 9)
#  define FIX_MULTICALL_REFCOUNT \
      if (CvDEPTH(multicall_cv) > 1) SvREFCNT_inc(multicall_cv);
#else
#  define FIX_MULTICALL_REFCOUNT
#endif

#ifndef CvISXSUB
#  define CvISXSUB(cv) CvXSUB(cv)
#endif

/* Not right, but close */
#if !defined cxinc && ( (PERL_VERSION == 8 && PERL_SUBVERSION >= 2) || (PERL_VERSION == 10 && PERL_SUBVERSION <= 1) )
# define cxinc() Perl_cxinc(aTHX)
#endif

#if PERL_VERSION < 17 || (PERL_VERSION == 17 && PERL_SUBVERSION < 7)
#  define SvREFCNT_dec_NN(sv)    SvREFCNT_dec(sv)
#endif

#if BITS_PER_WORD == 32
  static const unsigned int uvmax_maxlen = 10;
  static const unsigned int ivmax_maxlen = 10;
  static const char uvmax_str[] = "4294967295";
  static const char ivmax_str[] = "2147483648";
#else
  static const unsigned int uvmax_maxlen = 20;
  static const unsigned int ivmax_maxlen = 19;
  static const char uvmax_str[] = "18446744073709551615";
  static const char ivmax_str[] =  "9223372036854775808";
#endif

#define MY_CXT_KEY "Math::Prime::Util::API_guts"
typedef struct {
  SV* const_int[4];   /* -1, 0, 1, 2 */
  HV* MPUroot;
  HV* MPUGMP;
  HV* MPUPP;
} my_cxt_t;

START_MY_CXT

/* Is this a pedantically valid integer?
 * Croaks if undefined or invalid.
 * Returns 0 if it is an object or a string too large for a UV.
 * Returns 1 if it is good to process by XS.
 */
static int _validate_int(pTHX_ SV* n, int negok)
{
  const char* maxstr;
  char* ptr;
  STRLEN i, len, maxlen;
  int ret, isbignum = 0, isneg = 0;

  /* TODO: magic, grok_number, etc. */
  if ((SvFLAGS(n) & (SVf_IOK |
#if PERL_REVISION >=5 && PERL_VERSION >= 9 && PERL_SUBVERSION >= 4
                     SVf_ROK |
#else
                     SVf_AMAGIC |
#endif
                     SVs_GMG )) == SVf_IOK) { /* If defined as number, use it */
    if (SvIsUV(n) || SvIVX(n) >= 0)  return 1; /* The normal case */
    if (negok)  return -1;
    else croak("Parameter '%" SVf "' must be a positive integer", n);
  }
  if (SvROK(n)) {
    if (sv_isa(n, "Math::BigInt") || sv_isa(n, "Math::BigFloat") ||
        sv_isa(n, "Math::Pari") || sv_isa(n, "Math::GMP") ||
        sv_isa(n, "Math::GMPz") )
      isbignum = 1;
    else
      return 0;
  }
  /* Without being very careful, don't process magic variables here */
  if (SvGAMAGIC(n) && !isbignum) return 0;
  if (!SvOK(n))  croak("Parameter must be defined");
  ptr = SvPV_nomg(n, len);             /* Includes stringifying bigints */
  if (len == 0 || ptr == 0)  croak("Parameter must be a positive integer");
  if (ptr[0] == '-' && negok) {
    isneg = 1; ptr++; len--;           /* Read negative sign */
  } else if (ptr[0] == '+') {
    ptr++; len--;                      /* Allow a single plus sign */
  }
  if (len == 0 || !isDIGIT(ptr[0]))
    croak("Parameter '%" SVf "' must be a positive integer", n);
  while (len > 0 && *ptr == '0')       /* Strip all leading zeros */
    { ptr++; len--; }
  if (len > uvmax_maxlen)              /* Huge number, don't even look at it */
    return 0;
  for (i = 0; i < len; i++)            /* Ensure all characters are digits */
    if (!isDIGIT(ptr[i]))
      croak("Parameter '%" SVf "' must be a positive integer", n);
  if (isneg == 1)                      /* Negative number (ignore overflow) */
    return -1;
  ret    = isneg ? -1           : 1;
  maxlen = isneg ? ivmax_maxlen : uvmax_maxlen;
  maxstr = isneg ? ivmax_str    : uvmax_str;
  if (len < maxlen)                    /* Valid small integer */
    return ret;
  for (i = 0; i < maxlen; i++) {       /* Check if in range */
    if (ptr[i] < maxstr[i]) return ret;
    if (ptr[i] > maxstr[i]) return 0;
  }
  return ret;                          /* value = UV_MAX/UV_MIN.  That's ok */
}

#define VCALL_ROOT 0x0
#define VCALL_PP 0x1
#define VCALL_GMP 0x2
/* Call a Perl sub to handle work for us. */
static int _vcallsubn(pTHX_ I32 flags, I32 stashflags, const char* name, int nargs)
{
    GV* gv = NULL;
    dMY_CXT;
    Size_t namelen = strlen(name);
    /* If given a GMP function, and GMP enabled, and function exists, use it. */
    int use_gmp = stashflags & VCALL_GMP && _XS_get_callgmp();
    assert(!(stashflags & ~(VCALL_PP|VCALL_GMP)));
    if (use_gmp && hv_exists(MY_CXT.MPUGMP,name,namelen)) {
      GV ** gvp = (GV**)hv_fetch(MY_CXT.MPUGMP,name,namelen,0);
      if (gvp) gv = *gvp;
    }
    if (!gv && (stashflags & VCALL_PP))
      perl_require_pv("Math/Prime/Util/PP.pm");
    if (!gv) {
      GV ** gvp = (GV**)hv_fetch(stashflags & VCALL_PP? MY_CXT.MPUPP : MY_CXT.MPUroot, name,namelen,0);
      if (gvp) gv = *gvp;
    }
    /* use PL_stack_sp in PUSHMARK macro directly it will be read after
      the possible mark stack extend */
    PUSHMARK(PL_stack_sp-nargs);
    /* no PUTBACK bc we didn't move global SP */
    return call_sv((SV*)gv, flags);
}
#define _vcallsub(func) (void)_vcallsubn(aTHX_ G_SCALAR, VCALL_ROOT, func, items)
#define _vcallsub_with_gmp(func) (void)_vcallsubn(aTHX_ G_SCALAR, VCALL_GMP|VCALL_PP, func, items)
#define _vcallsub_with_pp(func) (void)_vcallsubn(aTHX_ G_SCALAR, VCALL_PP, func, items)

/* In my testing, this constant return works fine with threads, but to be
 * correct (see perlxs) one has to make a context, store separate copies in
 * each one, then retrieve them from a struct using a hash index.  This
 * defeats the purpose if only done once. */
#define RETURN_NPARITY(ret) \
  do { int r_ = ret; \
       dMY_CXT; \
       if (r_ >= -1 && r_ <= 2) { ST(0) = MY_CXT.const_int[r_+1]; XSRETURN(1); } \
       else                     { XSRETURN_IV(r_);                      } \
  } while (0)
#define PUSH_NPARITY(ret) \
  do { int r_ = ret; \
       if (r_ >= -1 && r_ <= 2) { PUSHs( MY_CXT.const_int[r_+1] );       } \
       else                     { PUSHs(sv_2mortal(newSViv(r_))); } \
  } while (0)


MODULE = Math::Prime::Util	PACKAGE = Math::Prime::Util

PROTOTYPES: ENABLE

BOOT:
{
    SV * sv = newSViv(BITS_PER_WORD);
    HV * stash = gv_stashpv("Math::Prime::Util", TRUE);
    newCONSTSUB(stash, "_XS_prime_maxbits", sv);
    { int i;
      MY_CXT_INIT;
      MY_CXT.MPUroot = stash;
      for (i = 0; i <= 3; i++) {
        MY_CXT.const_int[i] = newSViv(i-1);
        SvREADONLY_on(MY_CXT.const_int[i]);
      }
      MY_CXT.MPUGMP = gv_stashpv("Math::Prime::Util::GMP", TRUE);
      MY_CXT.MPUPP = gv_stashpv("Math::Prime::Util::PP", TRUE);
    }
}

#if defined(USE_ITHREADS) && defined(MY_CXT_KEY)

void
CLONE(...)
PREINIT:
  int i;
PPCODE:
  {
    MY_CXT_CLONE; /* possible declaration */
    for (i = 0; i <= 3; i++) {
      MY_CXT.const_int[i] = newSViv(i-1);
      SvREADONLY_on(MY_CXT.const_int[i]);
    }
    MY_CXT.MPUroot = gv_stashpv("Math::Prime::Util", TRUE);
    MY_CXT.MPUGMP = gv_stashpv("Math::Prime::Util::GMP", TRUE);
    MY_CXT.MPUPP = gv_stashpv("Math::Prime::Util::PP", TRUE);
  }
  return; /* skip implicit PUTBACK, returning @_ to caller, more efficient*/

#endif

void
END(...)
PREINIT:
  dMY_CXT;
  int i;
PPCODE:
  for (i = 0; i <= 3; i++) {
    SV * const sv = MY_CXT.const_int[i];
    MY_CXT.const_int[i] = NULL;
    SvREFCNT_dec_NN(sv);
  } /* stashes are owned by stash tree, no refcount on them in MY_CXT */
  MY_CXT.MPUroot = NULL;
  MY_CXT.MPUGMP = NULL;
  MY_CXT.MPUPP = NULL;
  _prime_memfreeall();
  return; /* skip implicit PUTBACK, returning @_ to caller, more efficient*/

void
prime_memfree()
  ALIAS:
    _XS_get_verbose = 1
    _XS_get_callgmp = 2
    _get_prime_cache_size = 3
  PREINIT:
    UV ret;
  PPCODE:
    switch (ix) {
      case 0:  prime_memfree(); goto return_nothing;
      case 1:  ret = _XS_get_verbose(); break;
      case 2:  ret = _XS_get_callgmp(); break;
      case 3:
      default: ret = get_prime_cache(0,0); break;
    }
    XSRETURN_UV(ret);
    return_nothing:

void
prime_precalc(IN UV n)
  ALIAS:
    _XS_set_verbose = 1
    _XS_set_callgmp = 2
  PPCODE:
    PUTBACK; /* SP is never used again, the 3 next func calls are tailcall
    friendly since this XSUB has nothing to do after the 3 calls return */
    switch (ix) {
      case 0:  prime_precalc(n);    break;
      case 1:  _XS_set_verbose(n);  break;
      default: _XS_set_callgmp(n);  break;
    }
    return; /* skip implicit PUTBACK */

void
prime_count(IN SV* svlo, ...)
  ALIAS:
    _XS_segment_pi = 1
    twin_prime_count = 2
  PREINIT:
    int lostatus, histatus;
    UV lo, hi;
  PPCODE:
    lostatus = _validate_int(aTHX_ svlo, 0);
    histatus = (items == 1 || _validate_int(aTHX_ ST(1), 0));
    if (lostatus == 1 && histatus == 1) {
      UV count = 0;
      if (items == 1) {
        lo = 2;
        hi = my_svuv(svlo);
      } else {
        lo = my_svuv(svlo);
        hi = my_svuv(ST(1));
      }
      if (lo <= hi) {
        if (ix == 2) {
          count = twin_prime_count(lo, hi);
        } else if (ix == 1 || (hi / (hi-lo+1)) > 100) {
          count = _XS_prime_count(lo, hi);
        } else {
          count = _XS_LMO_pi(hi);
          if (lo > 2)
            count -= _XS_LMO_pi(lo-1);
        }
      }
      XSRETURN_UV(count);
    }
    switch (ix) {
      case 0:
      case 1: _vcallsubn(aTHX_ GIMME_V, VCALL_ROOT, "_generic_prime_count", items); break;
      case 2:
      default:_vcallsub_with_pp("twin_prime_count");  break;
    }
    return; /* skip implicit PUTBACK */

UV
_XS_LMO_pi(IN UV n)
  ALIAS:
    _XS_legendre_pi = 1
    _XS_meissel_pi = 2
    _XS_lehmer_pi = 3
    _XS_LMOS_pi = 4
  PREINIT:
    UV ret;
  CODE:
    switch (ix) {
      case 0: ret = _XS_LMO_pi(n); break;
      case 1: ret = _XS_legendre_pi(n); break;
      case 2: ret = _XS_meissel_pi(n); break;
      case 3: ret = _XS_lehmer_pi(n); break;
      default:ret = _XS_LMOS_pi(n); break;
    }
    RETVAL = ret;
  OUTPUT:
    RETVAL

void
sieve_primes(IN UV low, IN UV high)
  ALIAS:
    trial_primes = 1
    erat_primes = 2
    segment_primes = 3
    segment_twin_primes = 4
  PREINIT:
    AV* av;
  PPCODE:
    av = newAV();
    {
      SV * retsv = sv_2mortal(newRV_noinc( (SV*) av ));
      PUSHs(retsv);
      PUTBACK;
      SP = NULL; /* never use SP again, poison */
    }
    if ((low <= 2) && (high >= 2) && ix != 4) { av_push(av, newSVuv( 2 )); }
    if ((low <= 3) && (high >= 3)) { av_push(av, newSVuv( 3 )); }
    if ((low <= 5) && (high >= 5)) { av_push(av, newSVuv( 5 )); }
    if (low < 7)  low = 7;
    if (low <= high) {
      if (ix == 4) high += 2;
      if (ix == 0) {                          /* Sieve with primary cache */
        START_DO_FOR_EACH_PRIME(low, high) {
          av_push(av,newSVuv(p));
        } END_DO_FOR_EACH_PRIME
      } else if (ix == 1) {                   /* Trial */
        for (low = next_prime(low-1);
             low <= high && low != 0;
             low = next_prime(low) ) {
          av_push(av,newSVuv(low));
        }
      } else if (ix == 2) {                   /* Erat with private memory */
        unsigned char* sieve = sieve_erat30(high);
        START_DO_FOR_EACH_SIEVE_PRIME( sieve, low, high ) {
           av_push(av,newSVuv(p));
        } END_DO_FOR_EACH_SIEVE_PRIME
        Safefree(sieve);
      } else if (ix == 3 || ix == 4) {        /* Segment */
        unsigned char* segment;
        UV seg_base, seg_low, seg_high, lastp = 0;
        void* ctx = start_segment_primes(low, high, &segment);
        while (next_segment_primes(ctx, &seg_base, &seg_low, &seg_high)) {
          START_DO_FOR_EACH_SIEVE_PRIME( segment, seg_low - seg_base, seg_high - seg_base )
            p += seg_base;
            if (ix == 3)            av_push(av,newSVuv( p ));
            else if (lastp+2 == p)  av_push(av,newSVuv( lastp ));
            lastp = p;
          END_DO_FOR_EACH_SIEVE_PRIME
        }
      }
    }
    return; /* skip implicit PUTBACK */

void
trial_factor(IN UV n, ...)
  ALIAS:
    fermat_factor = 1
    holf_factor = 2
    squfof_factor = 3
    prho_factor = 4
    pplus1_factor = 5
    pbrent_factor = 6
    pminus1_factor = 7
  PREINIT:
    UV arg1, arg2;
    static const UV default_arg1[] =
       {0,     64000000, 8000000, 4000000, 4000000, 200, 4000000, 1000000};
     /* Trial, Fermat,   Holf,    SQUFOF,  PRHO,    P+1, Brent,    P-1 */
  PPCODE:
    if (n == 0)  XSRETURN_UV(0);
    /* Must read arguments before pushing anything */
    arg1 = (items >= 2) ? my_svuv(ST(1)) : default_arg1[ix];
    arg2 = (items >= 3) ? my_svuv(ST(2)) : 0;
    /* Small factors */
    while ( (n% 2) == 0 ) {  n /=  2;  XPUSHs(sv_2mortal(newSVuv( 2 ))); }
    while ( (n% 3) == 0 ) {  n /=  3;  XPUSHs(sv_2mortal(newSVuv( 3 ))); }
    while ( (n% 5) == 0 ) {  n /=  5;  XPUSHs(sv_2mortal(newSVuv( 5 ))); }
    if (n == 1) {  /* done */ }
    else if (_XS_is_prime(n)) { XPUSHs(sv_2mortal(newSVuv( n ))); }
    else {
      UV factors[MPU_MAX_FACTORS+1];
      int i, nfactors = 0;
      switch (ix) {
        case 0:  nfactors = trial_factor  (n, factors, arg1);  break;
        case 1:  nfactors = fermat_factor (n, factors, arg1);  break;
        case 2:  nfactors = holf_factor   (n, factors, arg1);  break;
        case 3:  nfactors = squfof_factor (n, factors, arg1);  break;
        case 4:  nfactors = prho_factor   (n, factors, arg1);  break;
        case 5:  nfactors = pplus1_factor (n, factors, arg1);  break;
        case 6:  if (items < 3) arg2 = 1;
                 nfactors = pbrent_factor (n, factors, arg1, arg2);  break;
        case 7:
        default: if (items < 3) arg2 = 10*arg1;
                 nfactors = pminus1_factor(n, factors, arg1, arg2);  break;
      }
      EXTEND(SP, nfactors);
      for (i = 0; i < nfactors; i++)
        PUSHs(sv_2mortal(newSVuv( factors[i] )));
    }

void
is_strong_pseudoprime(IN SV* svn, ...)
  PREINIT:
    int c, status = 1;
  PPCODE:
    if (items < 2)
      croak("No bases given to is_strong_pseudoprime");
    /* Check all arguments */
    for (c = 0; c < items && status == 1; c++)
      if (_validate_int(aTHX_ ST(c), 0) != 1)
        status = 0;
    if (status == 1) {
      UV n = my_svuv(svn);
      int b, ret = 1;
      if      (n < 4)        { ret = (n >= 2); } /* 0,1 composite; 2,3 prime */
      else if ((n % 2) == 0) { ret = 0; }        /* evens composite */
      else {
        UV bases[32];
        for (c = 1; c < items && ret == 1; ) {
          for (b = 0; b < 32 && c < items; c++)
            bases[b++] = my_svuv(ST(c));
          ret = _XS_miller_rabin(n, bases, b);
        }
      }
      RETURN_NPARITY(ret);
    }
    _vcallsub_with_gmp("is_strong_pseudoprime");
    return; /* skip implicit PUTBACK */

void
gcd(...)
  PROTOTYPE: @
  ALIAS:
    lcm = 1
    vecmin = 2
    vecmax = 3
    vecsum = 4
    vecprod = 5
  PREINIT:
    int i, status = 1;
    UV ret, nullv, n;
  PPCODE:
    if (ix == 2 || ix == 3) {
      UV retindex = 0;
      int sign, minmax = (ix == 2);
      if (items == 0) XSRETURN_UNDEF;
      if (items == 1) XSRETURN(1);
      status = _validate_int(aTHX_ ST(0), 2);
      if (status != 0 && items > 1) {
        sign = status;
        ret = my_svuv(ST(0));
        for (i = 1; i < items; i++) {
          status = _validate_int(aTHX_ ST(i), 2);
          if (status == 0) break;
          n = my_svuv(ST(i));
          if (( (sign == -1 && status == 1) ||
                (n >= ret && sign == status)
              ) ? !minmax : minmax ) {
            sign = status;
            ret = n;
            retindex = i;
          }
        }
      }
      if (status != 0) {
        ST(0) = ST(retindex);
        XSRETURN(1);
      }
    } else if (ix == 4) {
      UV lo = 0;
      IV hi = 0;
      for (ret = i = 0; i < items; i++) {
        status = _validate_int(aTHX_ ST(i), 2);
        if (status == 0) break;
        n = my_svuv(ST(i));
        if (status == 1) {
          hi += (n > (UV_MAX - lo));
        } else {
          if (UV_MAX-n == (UV)IV_MAX) { status = 0; break; }  /* IV Overflow */
          hi -= ((UV_MAX-n) >= lo);
        }
        lo += n;
      }
      if (status != 0 && hi == -1 && lo > IV_MAX)  XSRETURN_IV((IV)lo);
      /* If status != 0 then the 128-bit result is:
       *   result = ( hi << 64) + lo     if hi > 0
       *   result = (-hi << 64) - lo     if hi < 0
       * We have to somehow return this as a bigint, which we can't do here.
       * Sad, because this will now be wasted work and slow. */
      if (hi != 0) status = 0;  /* Overflow */
      ret = lo;
    } else if (ix == 5) {
      int sign = 1;
      ret = 1;
      for (i = 0; i < items; i++) {
        status = _validate_int(aTHX_ ST(i), 2);
        if (status == 0) break;
        n = (status == 1) ? my_svuv(ST(i)) : (UV)-my_sviv(ST(i));
        if (ret > 0 && n > UV_MAX/ret) { status = 0; break; }
        sign *= status;
        ret *= n;
      }
      if (sign == -1 && status != 0) {
        if (ret <= (UV)IV_MAX)  XSRETURN_IV(-(IV)ret);
        else                    status = 0;
      }
    } else {
      /* For each arg, while valid input, validate+gcd/lcm.  Shortcut stop. */
      if (ix == 0) { ret = 0; nullv = 1; }
      else         { ret = (items == 0) ? 0 : 1; nullv = 0; }
      for (i = 0; i < items && ret != nullv && status != 0; i++) {
        status = _validate_int(aTHX_ ST(i), 2);
        if (status == 0)
          break;
        n = status * my_svuv(ST(i));  /* n = abs(arg) */
        if (i == 0) {
          ret = n;
        } else {
          UV gcd = gcd_ui(ret, n);
          if (ix == 0) {
            ret = gcd;
          } else {
            n /= gcd;
            if (n <= (UV_MAX / ret) )    ret *= n;
            else                         status = 0;   /* Overflow */
          }
        }
      }
    }
    if (status != 0)
      XSRETURN_UV(ret);
    switch (ix) {
      case 0: _vcallsub_with_gmp("gcd");   break;
      case 1: _vcallsub_with_gmp("lcm");   break;
      case 2: _vcallsub_with_gmp("vecmin"); break;
      case 3: _vcallsub_with_gmp("vecmax"); break;
      case 4: _vcallsub_with_pp("vecsum");  break;
      case 5:
      default:_vcallsub_with_pp("vecprod");  break;
    }
    return; /* skip implicit PUTBACK */

void
chinese(...)
  PROTOTYPE: @
  PREINIT:
    int i, status;
    UV* an;
    UV ret;
  PPCODE:
    status = 1;
    New(0, an, 2*items, UV);
    ret = 0;
    for (i = 0; i < items; i++) {
      AV* av;
      SV** psva;
      SV** psvn;
      if (!SvROK(ST(i)) || SvTYPE(SvRV(ST(i))) != SVt_PVAV || av_len((AV*)SvRV(ST(i))) != 1)
        croak("chinese arguments are two-element array references");
      av = (AV*) SvRV(ST(i));
      psva = av_fetch(av, 0, 0);
      psvn = av_fetch(av, 1, 0);
      if (psva == 0 || psvn == 0 || _validate_int(aTHX_ *psva, 1) != 1 || !_validate_int(aTHX_ *psvn, 0)) {
        status = 0;
        break;
      }
      an[i+0]     = my_svuv(*psva);
      an[i+items] = my_svuv(*psvn);
    }
    if (status)
      ret = chinese(an, an+items, items, &status);
    Safefree(an);
    if (status == -1) XSRETURN_UNDEF;
    if (status)       XSRETURN_UV(ret);
    _vcallsub_with_pp("chinese");
    return; /* skip implicit PUTBACK */

void
_XS_lucas_sequence(IN UV n, IN IV P, IN IV Q, IN UV k)
  PREINIT:
    UV U, V, Qk;
  PPCODE:
    lucas_seq(&U, &V, &Qk,  n, P, Q, k);
    PUSHs(sv_2mortal(newSVuv( U )));    /* 4 args in, 3 out, no EXTEND needed */
    PUSHs(sv_2mortal(newSVuv( V )));
    PUSHs(sv_2mortal(newSVuv( Qk )));

void
is_prime(IN SV* svn, ...)
  ALIAS:
    is_prob_prime = 1
    is_bpsw_prime = 2
    is_aks_prime = 3
    is_lucas_pseudoprime = 4
    is_strong_lucas_pseudoprime = 5
    is_extra_strong_lucas_pseudoprime = 6
    is_frobenius_pseudoprime = 7
    is_frobenius_underwood_pseudoprime = 8
    is_perrin_pseudoprime = 9
    is_power = 10
    is_pseudoprime = 11
    is_almost_extra_strong_lucas_pseudoprime = 12
  PREINIT:
    int status;
  PPCODE:
    status = _validate_int(aTHX_ svn, 1);
    if (status != 0) {
      int ret = 0;
      if (status == 1) {
        UV n = my_svuv(svn);
        UV a = (items == 1) ? 0 : my_svuv(ST(1));
        switch (ix) {
          case 0:
          case 1:  ret = _XS_is_prime(n);  break;
          case 2:  ret = _XS_BPSW(n);      break;
          case 3:  ret = _XS_is_aks_prime(n); break;
          case 4:  ret = _XS_is_lucas_pseudoprime(n, 0); break;
          case 5:  ret = _XS_is_lucas_pseudoprime(n, 1); break;
          case 6:  ret = _XS_is_lucas_pseudoprime(n, 2); break;
          case 7:  {
                     /* IV P = 1, Q = -1; */ /* Fibonacci polynomial */
                     IV P = 0, Q = 0;        /* Q=2,P=least odd s.t. (D|n)=-1 */
                     if (items == 3) { P = my_sviv(ST(1)); Q = my_sviv(ST(2)); }
                     else if (items != 1) croak("is_frobenius_pseudoprime takes P,Q");
                     ret = is_frobenius_pseudoprime(n, P, Q);
                   } break;
          case 8:  ret = _XS_is_frobenius_underwood_pseudoprime(n); break;
          case 9:  ret = is_perrin_pseudoprime(n); break;
          case 10: ret = is_power(n, a); break;
          case 11: ret = _XS_is_pseudoprime(n, (items == 1) ? 2 : a); break;
          case 12:
          default: ret = _XS_is_almost_extra_strong_lucas_pseudoprime
                         (n, (items == 1) ? 1 : a); break;
        }
      }
      RETURN_NPARITY(ret);
    }
    switch (ix) {
      case 0: _vcallsub_with_gmp("is_prime");       break;
      case 1: _vcallsub_with_gmp("is_prob_prime");  break;
      case 2: _vcallsub_with_gmp("is_bpsw_prime");  break;
      case 3: _vcallsub_with_gmp("is_aks_prime"); break;
      case 4: _vcallsub_with_gmp("is_lucas_pseudoprime"); break;
      case 5: _vcallsub_with_gmp("is_strong_lucas_pseudoprime"); break;
      case 6: _vcallsub_with_gmp("is_extra_strong_lucas_pseudoprime"); break;
      case 7: _vcallsub_with_gmp("is_frobenius_pseudoprime"); break;
      case 8: _vcallsub_with_gmp("is_frobenius_underwood_pseudoprime"); break;
      case 9: _vcallsub_with_gmp("is_perrin_pseudoprime"); break;
      case 10:_vcallsub_with_gmp("is_power"); break;
      case 11:_vcallsub_with_gmp("is_pseudoprime"); break;
      case 12:
      default:_vcallsub_with_gmp("is_almost_extra_strong_lucas_pseudoprime"); break;
    }
    return; /* skip implicit PUTBACK */

void
next_prime(IN SV* svn)
  ALIAS:
    prev_prime = 1
    nth_prime = 2
    nth_prime_upper = 3
    nth_prime_lower = 4
    nth_prime_approx = 5
    nth_twin_prime = 6
    nth_twin_prime_approx = 7
    prime_count_upper = 8
    prime_count_lower = 9
    prime_count_approx = 10
    twin_prime_count_approx = 11
  PPCODE:
    if (_validate_int(aTHX_ svn, 0)) {
      UV n = my_svuv(svn);
      if ( (n >= MPU_MAX_PRIME     && ix == 0) ||
           (n >= MPU_MAX_PRIME_IDX && (ix==2 || ix==3 || ix==4 || ix==5)) ||
           (n >= MPU_MAX_TWIN_PRIME_IDX && (ix==6 || ix==7)) ) {
        /* Out of range.  Fall through to Perl. */
      } else {
        UV ret;
        switch (ix) {
          case 0: ret = next_prime(n);  break;
          case 1: ret = (n < 3) ? 0 : prev_prime(n);  break;
          case 2: ret = nth_prime(n); break;
          case 3: ret = nth_prime_upper(n); break;
          case 4: ret = nth_prime_lower(n); break;
          case 5: ret = nth_prime_approx(n); break;
          case 6: ret = nth_twin_prime(n); break;
          case 7: ret = nth_twin_prime_approx(n); break;
          case 8: ret = prime_count_upper(n); break;
          case 9: ret = prime_count_lower(n); break;
          case 10:ret = prime_count_approx(n); break;
          case 11:
          default:ret = twin_prime_count_approx(n); break;
        }
        XSRETURN_UV(ret);
      }
    }
    switch (ix) {
      /*
      case 0:  _vcallsub_with_gmp("next_prime");        break;
      case 1:  _vcallsub_with_gmp("prev_prime");        break;
      */
      case 0:  _vcallsub("_generic_next_prime");        break;
      case 1:  _vcallsub("_generic_prev_prime");        break;
      case 2:  _vcallsub_with_pp("nth_prime");          break;
      case 3:  _vcallsub_with_pp("nth_prime_upper");    break;
      case 4:  _vcallsub_with_pp("nth_prime_lower");    break;
      case 5:  _vcallsub_with_pp("nth_prime_approx");   break;
      case 6:  _vcallsub_with_pp("nth_twin_prime");     break;
      case 7:  _vcallsub_with_pp("nth_twin_prime_approx"); break;
      case 8:  _vcallsub_with_pp("prime_count_upper");  break;
      case 9:  _vcallsub_with_pp("prime_count_lower");  break;
      case 10: _vcallsub_with_pp("prime_count_approx"); break;
      case 11:
      default: _vcallsub_with_pp("twin_prime_count_approx"); break;
    }
    return; /* skip implicit PUTBACK */

void Pi(IN UV digits = 0)
  PREINIT:
    NV pival = 3.141592653589793238462643383279502884197169L;
    UV mantsize = DBL_MANT_DIG / 3.322;   /* Let long doubles go to BF */
  PPCODE:
    if (digits == 0) {
      XSRETURN_NV( pival );
    } else if (digits <= mantsize && digits <= 40) {
      char t[40+2];
      NV pi;
      (void)sprintf(t, "%.*"NVff, (int)(digits-1), pival);
#if defined(USE_LONG_DOUBLE) && defined(HAS_LONG_DOUBLE)
      pi = strtold(t, NULL);
#else
      pi = strtod(t, NULL);
#endif
      XSRETURN_NV( pi );
    } else {
      _vcallsub_with_pp("Pi");
      return;
    }

void
_pidigits(IN int digits)
  PPCODE:
    if (digits == 1) {
      XSRETURN_UV(3);
    } else {
      char *out;
      IV  *a;
      IV b, c, d, e, f, g, i,  d4, d3, d2, d1;

      digits++;   /* For rounding */
      b = d = e = g = i = 0;  f = 10000;
      c = 14*(digits/4 + 2);
      New(0, a, c, IV);
      New(0, out, digits+5+1, char);
      *out++ = '3';  /* We'll turn "31415..." into "3.1415..." */
      for (b = 0; b < c; b++)  a[b] = 20000000;
      
      while ((b = c -= 14) > 0 && i < digits) {
        d = e = d % f;
        while (--b > 0) {
          d = d * b + a[b];
          g = (b << 1) - 1;
          a[b] = (d % g) * f;
          d /= g;
        }
        /* sprintf(out+i, "%04d", e+d/f);   i += 4; */
        d4 = e+d/f;
        if (d4 > 9999) {
          d4 -= 10000;
          out[i-1]++;
          for (b=i-1; out[b] == '0'+1; b--) { out[b]='0'; out[b-1]++; }
        }
        d3 = d4/10;  d2 = d3/10;  d1 = d2/10;
        out[i++] = '0' + d1;
        out[i++] = '0' + d2-d1*10;
        out[i++] = '0' + d3-d2*10;
        out[i++] = '0' + d4-d3*10;
      }
      Safefree(a);
      if (out[digits-1] >= '5') out[digits-2]++;  /* Round */
      for (i = digits-2; out[i] == '9'+1; i--)    /* Keep rounding */
        { out[i] = '0';  out[i-1]++; }
      digits--;  /* Undo the extra digit we used for rounding */
      out[digits] = '\0';
      *out-- = '.';
      XPUSHs(sv_2mortal(newSVpvn(out, digits+1)));
      Safefree(out);
    }


void
factor(IN SV* svn)
  ALIAS:
    factor_exp = 1
    divisors = 2
  PREINIT:
    U32 gimme_v;
    int status, i, nfactors;
  PPCODE:
    gimme_v = GIMME_V;
    status = _validate_int(aTHX_ svn, 0);
    if (status == 1) {
      UV factors[MPU_MAX_FACTORS+1];
      UV exponents[MPU_MAX_FACTORS+1];
      UV n = my_svuv(svn);
      if (gimme_v == G_SCALAR) {
        switch (ix) {
          case 0:  nfactors = factor(n, factors);        break;
          case 1:  nfactors = factor_exp(n, factors, 0); break;
          default: nfactors = divisor_sum(n, 0);         break;
        }
        PUSHs(sv_2mortal(newSVuv( nfactors )));
      } else if (gimme_v == G_ARRAY) {
        switch (ix) {
          case 0:  nfactors = factor(n, factors);
                   EXTEND(SP, nfactors);
                   for (i = 0; i < nfactors; i++)
                     PUSHs(sv_2mortal(newSVuv( factors[i] )));
                   break;
          case 1:  nfactors = factor_exp(n, factors, exponents);
                   /* if (n == 1)  XSRETURN_EMPTY; */
                   EXTEND(SP, nfactors);
                   for (i = 0; i < nfactors; i++) {
                     AV* av = newAV();
                     av_push(av, newSVuv(factors[i]));
                     av_push(av, newSVuv(exponents[i]));
                     PUSHs( sv_2mortal(newRV_noinc( (SV*) av )) );
                   }
                   break;
          default: {
                     UV ndivisors;
                     UV* divs = _divisor_list(n, &ndivisors);
                     EXTEND(SP, ndivisors);
                     for (i = 0; (UV)i < ndivisors; i++)
                       PUSHs(sv_2mortal(newSVuv( divs[i] )));
                     Safefree(divs);
                   }
                   break;
        }
      }
    } else {
      switch (ix) {
        case 0:  _vcallsubn(aTHX_ gimme_v, VCALL_ROOT, "_generic_factor", 1);     break;
        case 1:  _vcallsubn(aTHX_ gimme_v, VCALL_ROOT, "_generic_factor_exp", 1); break;
        default: _vcallsubn(aTHX_ gimme_v, VCALL_GMP|VCALL_PP, "divisors", 1);   break;
      }
      return; /* skip implicit PUTBACK */
    }

void
divisor_sum(IN SV* svn, ...)
  PREINIT:
    SV* svk;
    int nstatus, kstatus;
  PPCODE:
    svk = (items > 1) ? ST(1) : 0;
    nstatus = _validate_int(aTHX_ svn, 0);
    kstatus = (items == 1 || (SvIOK(svk) && SvIV(svk)))  ?  1  :  0;
    if (nstatus == 1 && kstatus == 1) {
      UV n = my_svuv(svn);
      UV k = (items > 1) ? my_svuv(svk) : 1;
      UV sigma = divisor_sum(n, k);
      if (sigma != 0)  XSRETURN_UV(sigma);   /* sigma 0 means overflow */
    }
    _vcallsub_with_gmp("divisor_sum");
    return; /* skip implicit PUTBACK */

void
znorder(IN SV* sva, IN SV* svn)
  ALIAS:
    binomial = 1
    jordan_totient = 2
    legendre_phi = 3
  PREINIT:
    int astatus, nstatus;
  PPCODE:
    astatus = _validate_int(aTHX_ sva, (ix==1) ? 2 : 0);
    nstatus = _validate_int(aTHX_ svn, (ix==1) ? 2 : 0);
    if (astatus != 0 && nstatus != 0) {
      UV a = my_svuv(sva);
      UV n = my_svuv(svn);
      UV ret;
      switch (ix) {
        case 0:  ret = znorder(a, n);
                 break;
        case 1:  if ( (astatus == 1 && (nstatus == -1 || n > a)) ||
                      (astatus ==-1 && (nstatus == -1 && n > a)) )
                   { ret = 0; break; }
                 if (nstatus == -1)
                   n = a - n; /* n<0,k<=n:  (-1)^(n-k) * binomial(-k-1,n-k) */
                 if (astatus == -1) {
                   ret = binomial( -my_sviv(sva)+n-1, n );
                   if (ret > 0 && ret <= (UV)IV_MAX)
                     XSRETURN_IV( (IV)ret * ((n&1) ? -1 : 1) );
                   goto overflow;
                 } else {
                   ret = binomial(a, n);
                   if (ret == 0)
                     goto overflow;
                 }
                 break;
        case 2:  ret = jordan_totient(a, n);
                 if (ret == 0 && n > 1)
                   goto overflow;
                 break;
        case 3:
        default: ret = legendre_phi(a, n);
                 break;
      }
      if (ret == 0 && ix == 0)  XSRETURN_UNDEF;  /* not defined */
      XSRETURN_UV(ret);
    }
    overflow:
    switch (ix) {
      case 0:  _vcallsub_with_pp("znorder");  break;
      case 1:  _vcallsub_with_pp("binomial");  break;
      case 2:  _vcallsub_with_pp("jordan_totient");  break;
      case 3:
      default: _vcallsub_with_pp("legendre_phi"); break;
    }
    return; /* skip implicit PUTBACK */

void
znlog(IN SV* sva, IN SV* svg, IN SV* svp)
  PREINIT:
    int astatus, gstatus, pstatus;
  PPCODE:
    astatus = _validate_int(aTHX_ sva, 0);
    gstatus = _validate_int(aTHX_ svg, 0);
    pstatus = _validate_int(aTHX_ svp, 0);
    if (astatus == 1 && gstatus == 1 && pstatus == 1) {
      UV a = my_svuv(sva), g = my_svuv(svg), p = my_svuv(svp);
      UV ret = znlog(a, g, p);
      /* TODO: perhaps return p to mean no solution? */
      if (ret == 0 && a > 1) XSRETURN_UNDEF;
      XSRETURN_UV(ret);
    }
    _vcallsub_with_gmp("znlog");
    return; /* skip implicit PUTBACK */

void
kronecker(IN SV* sva, IN SV* svb)
  ALIAS:
    valuation = 1
    invmod = 2
  PREINIT:
    int astatus, bstatus, abpositive, abnegative;
  PPCODE:
    astatus = _validate_int(aTHX_ sva, 2);
    bstatus = _validate_int(aTHX_ svb, 2);
    if (astatus != 0 && bstatus != 0) {
      if (ix == 0) {
        /* Are both a and b positive? */
        abpositive = astatus == 1 && bstatus == 1;
        /* Will both fit in IVs?  We should use a bitmask return. */
        abnegative = !abpositive
                     && (SvIOK(sva) && !SvIsUV(sva))
                     && (SvIOK(svb) && !SvIsUV(svb));
        if (abpositive || abnegative) {
          UV a = my_svuv(sva);
          UV b = my_svuv(svb);
          int k = (abpositive) ? kronecker_uu(a,b) : kronecker_ss(a,b);
          RETURN_NPARITY(k);
        }
      } else if (ix == 1) {
        UV n = (astatus == -1) ? (UV)(-(my_sviv(sva))) : my_svuv(sva);
        UV k = (bstatus == -1) ? (UV)(-(my_sviv(svb))) : my_svuv(svb);
        /* valuation of 0-2 is very common, so return a constant if possible */
        RETURN_NPARITY( valuation(n, k) );
      } else {
        UV a, n, ret = 0;
        n = (bstatus != -1) ? my_svuv(svb) : (UV)(-(my_sviv(svb)));
        if (n > 0) {
          a = (astatus != -1) ? my_svuv(sva)
                              : n * ((UV)(-my_sviv(sva))/n + 1) + my_sviv(sva);
          if (a > 0) {
            if (n == 1) XSRETURN_UV(0);
            ret = modinverse(a, n);
          }
        }
        if (ret == 0) XSRETURN_UNDEF;
        XSRETURN_UV(ret);
      }
    }
    switch (ix) {
      case 0:  _vcallsub_with_gmp("kronecker");  break;
      case 1:  _vcallsub_with_gmp("valuation"); break;
      case 2:
      default: _vcallsub_with_gmp("invmod"); break;
    }
    return; /* skip implicit PUTBACK */

void
gcdext(IN SV* sva, IN SV* svb)
  PREINIT:
    int astatus, bstatus;
  PPCODE:
    astatus = _validate_int(aTHX_ sva, 2);
    bstatus = _validate_int(aTHX_ svb, 2);
    /* TODO: These should be built into validate_int */
    if ( (astatus == 1 && SvIsUV(sva)) || (astatus == -1 && !SvIOK(sva)) )
      astatus = 0;  /* too large */
    if ( (bstatus == 1 && SvIsUV(svb)) || (bstatus == -1 && !SvIOK(svb)) )
      bstatus = 0;  /* too large */
    if (astatus != 0 && bstatus != 0) {
      IV u, v, d;
      IV a = my_sviv(sva);
      IV b = my_sviv(svb);
      d = gcdext(a, b, &u, &v, 0, 0);
      XPUSHs(sv_2mortal(newSViv( u )));
      XPUSHs(sv_2mortal(newSViv( v )));
      XPUSHs(sv_2mortal(newSViv( d )));
    } else {
      _vcallsubn(aTHX_ GIMME_V, VCALL_PP, "gcdext", items);
      return; /* skip implicit PUTBACK */
    }

NV
_XS_ExponentialIntegral(IN SV* x)
  ALIAS:
    _XS_LogarithmicIntegral = 1
    _XS_RiemannZeta = 2
    _XS_RiemannR = 3
    _XS_LambertW = 4
  PREINIT:
    NV nv, ret;
  CODE:
    nv = SvNV(x);
    switch (ix) {
      case 0: ret = (NV) _XS_ExponentialIntegral(nv); break;
      case 1: ret = (NV) _XS_LogarithmicIntegral(nv); break;
      case 2: ret = (NV) ld_riemann_zeta(nv); break;
      case 3: ret = (NV) _XS_RiemannR(nv); break;
      case 4:
      default:ret = (NV) lambertw(nv); break;
    }
    RETVAL = ret;
  OUTPUT:
    RETVAL

void
euler_phi(IN SV* svlo, ...)
  ALIAS:
    moebius = 1
  PREINIT:
    int lostatus, histatus;
  PPCODE:
    lostatus = _validate_int(aTHX_ svlo, 2);
    histatus = (items == 1 || _validate_int(aTHX_ ST(1), 0));
    if (items == 1 && lostatus != 0) {
      /* input is a single value and in UV/IV range */
      if (ix == 0) {
        UV n = (lostatus == -1) ? 0 : my_svuv(svlo);
        XSRETURN_UV(totient(n));
      } else {
        UV n = (lostatus == -1) ? (UV)(-(my_sviv(svlo))) : my_svuv(svlo);
        RETURN_NPARITY(moebius(n));
      }
    } else if (items == 2 && lostatus == 1 && histatus == 1) {
      /* input is a range and both lo and hi are non-negative */
      UV lo = my_svuv(svlo);
      UV hi = my_svuv(ST(1));
      if (lo <= hi) {
        UV i;
        EXTEND(SP, hi-lo+1);
        if (ix == 0) {
          UV  arraylo = (lo < 100)  ?  0  :  lo;
          UV* totients = _totient_range(arraylo, hi);
          for (i = lo; i <= hi; i++)
            PUSHs(sv_2mortal(newSVuv(totients[i-arraylo])));
          Safefree(totients);
        } else {
          signed char* mu = _moebius_range(lo, hi);
          dMY_CXT;
          for (i = lo; i <= hi; i++)
            PUSH_NPARITY(mu[i-lo]);
          Safefree(mu);
        }
      }
    } else {
      /* Whatever we didn't handle above */
      U32 gimme_v = GIMME_V;
      switch (ix) {
        case 0:  _vcallsubn(aTHX_ gimme_v, VCALL_PP, "euler_phi", items);break;
        case 1:
        default: _vcallsubn(aTHX_ gimme_v, VCALL_GMP|VCALL_PP, "moebius", items);  break;
      }
      return;
    }

void
carmichael_lambda(IN SV* svn)
  ALIAS:
    mertens = 1
    liouville = 2
    chebyshev_theta = 3
    chebyshev_psi = 4
    factorial = 5
    exp_mangoldt = 6
    znprimroot = 7
  PREINIT:
    int status;
  PPCODE:
    status = _validate_int(aTHX_ svn, (ix >= 6) ? 1 : 0);
    if (status != 0) {
      UV r, n = my_svuv(svn);
      switch (ix) {
        case 0:  XSRETURN_UV(carmichael_lambda(n)); break;
        case 1:  XSRETURN_IV(mertens(n)); break;
        case 2:  { UV factors[MPU_MAX_FACTORS+1];
                   int nfactors = factor(my_svuv(svn), factors);
                   RETURN_NPARITY( (nfactors & 1) ? -1 : 1 ); }
                 break;
        case 3:  XSRETURN_NV(chebyshev_function(n, 0)); break;
        case 4:  XSRETURN_NV(chebyshev_function(n, 1)); break;
        case 5:  r = factorial(n);
                 if (r != 0) XSRETURN_UV(r);
                 status = 0; break;
        case 6:  XSRETURN_UV( (status == -1) ? 1 : exp_mangoldt(n) ); break;
        case 7:
        default: if (status == -1) n = -(IV)n;
                 r = znprimroot(n);
                 if (r == 0 && n != 1)  XSRETURN_UNDEF;  /* No root */
                 XSRETURN_UV(r);  break;
      }
    }
    switch (ix) {
      case 0:  _vcallsub_with_gmp("carmichael_lambda");  break;
      case 1:  _vcallsub_with_pp("mertens"); break;
      case 2:  _vcallsub_with_gmp("liouville"); break;
      case 3:  _vcallsub_with_pp("chebyshev_theta"); break;
      case 4:  _vcallsub_with_pp("chebyshev_psi"); break;
      case 5:  _vcallsub_with_pp("factorial"); break;
      case 6:  _vcallsub_with_gmp("exp_mangoldt"); break;
      case 7:
      default: _vcallsub_with_gmp("znprimroot");
    }
    return; /* skip implicit PUTBACK */

bool
_validate_num(SV* svn, ...)
  PREINIT:
    SV* sv1;
    SV* sv2;
  CODE:
    /* Internal function.  Emulate the PP version of this:
     *   $is_valid = _validate_num( $n [, $min [, $max] ] )
     * Return 0 if we're befuddled by the input.
     * Otherwise croak if n isn't >= 0 and integer, n < min, or n > max.
     * Small bigints will be converted to scalars.
     */
    RETVAL = FALSE;
    if (_validate_int(aTHX_ svn, 0)) {
      if (SvROK(svn)) {  /* Convert small Math::BigInt object into scalar */
        UV n = my_svuv(svn);
#if PERL_REVISION <= 5 && PERL_VERSION < 8 && BITS_PER_WORD == 64
        sv_setpviv(svn, n);
#else
        sv_setuv(svn, n);
#endif
      }
      if (items > 1 && ((sv1 = ST(1)), SvOK(sv1))) {
        UV n = my_svuv(svn);
        UV min = my_svuv(sv1);
        if (n < min)
          croak("Parameter '%"UVuf"' must be >= %"UVuf, n, min);
        if (items > 2 && ((sv2 = ST(2)), SvOK(sv2))) {
          UV max = my_svuv(sv2);
          if (n > max)
            croak("Parameter '%"UVuf"' must be <= %"UVuf, n, max);
          MPUassert( items <= 3, "_validate_num takes at most 3 parameters");
        }
      }
      RETVAL = TRUE;
    }
  OUTPUT:
    RETVAL

void
forprimes (SV* block, IN SV* svbeg, IN SV* svend = 0)
  PROTOTYPE: &$;$
  PREINIT:
    GV *gv;
    HV *stash;
    SV* svarg;
    CV *cv;
    unsigned char* segment;
    UV beg, end, seg_base, seg_low, seg_high;
  PPCODE:
    cv = sv_2cv(block, &stash, &gv, 0);
    if (cv == Nullcv)
      croak("Not a subroutine reference");

    if (!_validate_int(aTHX_ svbeg, 0) || (items >= 3 && !_validate_int(aTHX_ svend,0))) {
      _vcallsubn(aTHX_ G_VOID|G_DISCARD, VCALL_ROOT, "_generic_forprimes", items);
      return;
    }

    if (items < 3) {
      beg = 2;
      end = my_svuv(svbeg);
    } else {
      beg = my_svuv(svbeg);
      end = my_svuv(svend);
    }

    SAVESPTR(GvSV(PL_defgv));
    svarg = newSVuv(beg);
    GvSV(PL_defgv) = svarg;
    /* Handle early part */
    while (beg < 6) {
      beg = (beg <= 2) ? 2 : (beg <= 3) ? 3 : 5;
      if (beg <= end) {
        sv_setuv(svarg, beg);
        PUSHMARK(SP);
        call_sv((SV*)cv, G_VOID|G_DISCARD);
      }
      beg += 1 + (beg > 2);
    }
#if USE_MULTICALL
    if (!CvISXSUB(cv) && beg <= end) {
      dMULTICALL;
      I32 gimme = G_VOID;
      PUSH_MULTICALL(cv);
      if (
#if BITS_PER_WORD == 64
          (beg >= UVCONST(     100000000000000) && end-beg <    100000) ||
          (beg >= UVCONST(      10000000000000) && end-beg <     40000) ||
          (beg >= UVCONST(       1000000000000) && end-beg <     17000) ||
#endif
          ((end-beg) < 500) ) {     /* MULTICALL next prime */
        for (beg = next_prime(beg-1); beg <= end && beg != 0; beg = next_prime(beg)) {
          sv_setuv(svarg, beg);
          MULTICALL;
        }
      } else {                      /* MULTICALL segment sieve */
        void* ctx = start_segment_primes(beg, end, &segment);
        while (next_segment_primes(ctx, &seg_base, &seg_low, &seg_high)) {
          int crossuv = (seg_high > IV_MAX) && !SvIsUV(svarg);
          START_DO_FOR_EACH_SIEVE_PRIME( segment, seg_low - seg_base, seg_high - seg_base ) {
            p += seg_base;
            /* sv_setuv(svarg, p); */
            if      (SvTYPE(svarg) != SVt_IV) { sv_setuv(svarg, p);            }
            else if (crossuv && p > IV_MAX)   { sv_setuv(svarg, p); crossuv=0; }
            else                              { SvUV_set(svarg, p);            }
            MULTICALL;
          } END_DO_FOR_EACH_SIEVE_PRIME
        }
        end_segment_primes(ctx);
      }
      FIX_MULTICALL_REFCOUNT;
      POP_MULTICALL;
    }
    else
#endif
    if (beg <= end) {               /* NO-MULTICALL segment sieve */
      void* ctx = start_segment_primes(beg, end, &segment);
      while (next_segment_primes(ctx, &seg_base, &seg_low, &seg_high)) {
        START_DO_FOR_EACH_SIEVE_PRIME( segment, seg_low - seg_base, seg_high - seg_base ) {
          sv_setuv(svarg, seg_base + p);
          PUSHMARK(SP);
          call_sv((SV*)cv, G_VOID|G_DISCARD);
        } END_DO_FOR_EACH_SIEVE_PRIME
      }
      end_segment_primes(ctx);
    }
    SvREFCNT_dec(svarg);

void
forcomposites (SV* block, IN SV* svbeg, IN SV* svend = 0)
  ALIAS:
    foroddcomposites = 1
  PROTOTYPE: &$;$
  PREINIT:
    UV beg, end;
    GV *gv;
    HV *stash;
    SV* svarg;  /* We use svarg to prevent clobbering $_ outside the block */
    CV *cv;
  PPCODE:
    cv = sv_2cv(block, &stash, &gv, 0);
    if (cv == Nullcv)
      croak("Not a subroutine reference");

    if (!_validate_int(aTHX_ svbeg, 0) || (items >= 3 && !_validate_int(aTHX_ svend,0))) {
      _vcallsubn(aTHX_ G_VOID|G_DISCARD, VCALL_ROOT, (ix == 0) ? "_generic_forcomposites" : "_generic_foroddcomposites", items);
      return;
    }

    if (items < 3) {
      beg = ix ? 9 : 4;
      end = my_svuv(svbeg);
    } else {
      beg = my_svuv(svbeg);
      end = my_svuv(svend);
    }

    SAVESPTR(GvSV(PL_defgv));
    svarg = newSVuv(0);
    GvSV(PL_defgv) = svarg;
#if USE_MULTICALL
    if (!CvISXSUB(cv) && end >= beg) {
      unsigned char* segment;
      UV seg_base, seg_low, seg_high, c, cbeg, cend, prevprime, nextprime;
      void* ctx;
      dMULTICALL;
      I32 gimme = G_VOID;
      PUSH_MULTICALL(cv);
      if (beg >= MPU_MAX_PRIME ||
#if BITS_PER_WORD == 64
          (beg >= UVCONST(     100000000000000) && end-beg <    120000) ||
          (beg >= UVCONST(      10000000000000) && end-beg <     50000) ||
          (beg >= UVCONST(       1000000000000) && end-beg <     20000) ||
#endif
          end-beg < 1000 ) {
        beg = (beg <= 4) ? 3 : beg-1;
        nextprime = next_prime(beg);
        while (beg++ < end) {
          if (beg == nextprime)     nextprime = next_prime(beg);
          else if (!ix || beg & 1)  { sv_setuv(svarg, beg); MULTICALL; }
        }
      } else {
        if (ix) {
          if (beg < 9)  beg = 9;
        } else if (beg <= 4) { /* sieve starts at 7, so handle this here */
          sv_setuv(svarg, 4);  MULTICALL;
          beg = 6;
        }
        /* Find the two primes that bound their interval. */
        /* beg must be < max_prime, and end >= max_prime is special. */
        prevprime = prev_prime(beg);
        nextprime = (end >= MPU_MAX_PRIME) ? MPU_MAX_PRIME : next_prime(end);
        ctx = start_segment_primes(beg, nextprime, &segment);
        while (next_segment_primes(ctx, &seg_base, &seg_low, &seg_high)) {
          START_DO_FOR_EACH_SIEVE_PRIME( segment, seg_low - seg_base, seg_high - seg_base ) {
            cbeg = prevprime+1;  if (cbeg < beg) cbeg = beg;
            prevprime = seg_base + p;
            cend = prevprime-1;  if (cend > end) cend = end;
            for (c = cbeg; c <= cend; c++) {
              if (!ix || c & 1) { sv_setuv(svarg, c);  MULTICALL; }
            }
          } END_DO_FOR_EACH_SIEVE_PRIME
        }
        end_segment_primes(ctx);
        if (end > nextprime)   /* Complete the case where end > max_prime */
          while (nextprime++ < end)
            if (!ix || nextprime & 1)
              { sv_setuv(svarg, nextprime);  MULTICALL; }
      }
      FIX_MULTICALL_REFCOUNT;
      POP_MULTICALL;
    }
    else
#endif
    if (beg <= end) {
      beg = (beg <= 4) ? 3 : beg-1;
      while (beg++ < end) {
        if ((!ix || beg&1) && !is_prob_prime(beg)) {
          sv_setuv(svarg, beg);
          PUSHMARK(SP);
          call_sv((SV*)cv, G_VOID|G_DISCARD);
        }
      }
    }
    SvREFCNT_dec(svarg);

void
fordivisors (SV* block, IN SV* svn)
  PROTOTYPE: &$
  PREINIT:
    UV i, n, ndivisors;
    UV *divs;
    GV *gv;
    HV *stash;
    SV* svarg;  /* We use svarg to prevent clobbering $_ outside the block */
    CV *cv;
  PPCODE:
    cv = sv_2cv(block, &stash, &gv, 0);
    if (cv == Nullcv)
      croak("Not a subroutine reference");

    if (!_validate_int(aTHX_ svn, 0)) {
      _vcallsubn(aTHX_ G_VOID|G_DISCARD, VCALL_ROOT, "_generic_fordivisors", 2);
      return;
    }

    n = my_svuv(svn);
    divs = _divisor_list(n, &ndivisors);

    SAVESPTR(GvSV(PL_defgv));
    svarg = newSVuv(0);
    GvSV(PL_defgv) = svarg;
#if USE_MULTICALL
    if (!CvISXSUB(cv)) {
      dMULTICALL;
      I32 gimme = G_VOID;
      PUSH_MULTICALL(cv);
      for (i = 0; i < ndivisors; i++) {
        sv_setuv(svarg, divs[i]);
        MULTICALL;
      }
      FIX_MULTICALL_REFCOUNT;
      POP_MULTICALL;
    }
    else
#endif
    {
      for (i = 0; i < ndivisors; i++) {
        sv_setuv(svarg, divs[i]);
        PUSHMARK(SP);
        call_sv((SV*)cv, G_VOID|G_DISCARD);
      }
    }
    SvREFCNT_dec(svarg);
    Safefree(divs);

void
forpart (SV* block, IN SV* svn, IN SV* svh = 0)
  PROTOTYPE: &$;$
  PREINIT:
    UV i, n, amin, amax, nmin, nmax;
    GV *gv;
    HV *stash;
    CV *cv;
    SV** svals;
  PPCODE:
    cv = sv_2cv(block, &stash, &gv, 0);
    if (cv == Nullcv)
      croak("Not a subroutine reference");
    if (!_validate_int(aTHX_ svn, 0)) {
      _vcallsub_with_pp("forpart");
      return;
    }
    n = my_svuv(svn);
    if (n > (UV_MAX-2)) croak("forpart argument overflow");

    New(0, svals, n+1, SV*);
    for (i = 0; i <= n; i++) {
      svals[i] = newSVuv(i);
      SvREADONLY_on(svals[i]);
    }

    amin = 0;  amax = n;  nmin = 0;  nmax = n;
    if (svh != 0) {
      HV* rhash;
      SV** svp;
      if (!SvROK(svh) || SvTYPE(SvRV(svh)) != SVt_PVHV)
        croak("forpart second argument must be a hash reference");
      rhash = (HV*) SvRV(svh);
      if ((svp = hv_fetchs(rhash, "n", 0)) != NULL)
        { nmin = my_svuv(*svp);  nmax = nmin; }
      if ((svp = hv_fetchs(rhash, "amin", 0)) != NULL) amin = my_svuv(*svp);
      if ((svp = hv_fetchs(rhash, "amax", 0)) != NULL) amax = my_svuv(*svp);
      if ((svp = hv_fetchs(rhash, "nmin", 0)) != NULL) nmin = my_svuv(*svp);
      if ((svp = hv_fetchs(rhash, "nmax", 0)) != NULL) nmax = my_svuv(*svp);

      if (amax > n) amax = n;
      if (nmax > n) nmax = n;
    }

    if (n==0 || (nmin <= nmax && amin <= amax && nmax > 0 && amax > 0))
    { /* ZS1 algorithm from Zoghbi and Stojmenovic 1998) */
      UV *x, m, h;
      New(0, x, n+2, UV);  /* plus 2 because of n=0 */
      for (i = 0; i <= n; i++)  x[i] = 1;
      x[1] = n;
      m = (n > 0) ? 1 : 0;   /* n=0 => one call with empty list */
      h = 1;

      if (x[1] > amax) { /* x[1] is always decreasing, so handle it here */
        UV t = n - amax;
        x[h] = amax;
        while (t >= amax) {  x[++h] = amax;  t -= amax;  }
        m = h + (t > 0);
        if (t > 1)  x[++h] = t;
      }

      /* More restriction optimizations would be useful. */
      while (1) {
        if (m >= nmin && m <= nmax && x[m] >= amin)
        { dSP; ENTER; PUSHMARK(SP);
          EXTEND(SP, m); for (i=1; i <= m; i++) { PUSHs(svals[x[i]]); }
          PUTBACK; call_sv((SV*)cv, G_VOID|G_DISCARD); LEAVE;
        }
        if (x[1] <= 1 || x[1] < amin) break;
        /* Skip forward if restricted and we can move on. */
        if (x[2] < amin || (m > nmax && (n-x[1]+x[2]-1)/x[2] >= nmax)) {
          for (m = 1; n >= (x[1] + m); m++)
            x[m+1] = 1;
          h = 1;
        }
        if (x[h] == 2) {
          m++;  x[h--] = 1;
        } else {
          UV r = x[h]-1;
          UV t = m-h+1;
          x[h] = r;
          while (t >= r) {  x[++h] = r;  t -= r;  }
          m = h + (t > 0);
          if (t > 1)  x[++h] = t;
        }
      }
      Safefree(x);
    }
    for (i = 0; i <= n; i++)
      SvREFCNT_dec(svals[i]);
    Safefree(svals);

void
forcomb (SV* block, IN SV* svn, IN SV* svk = 0)
  ALIAS:
    forperm = 1
  PROTOTYPE: &$;$
  PREINIT:
    UV i, n, k, j, m;
    GV *gv;
    HV *stash;
    CV *cv;
    SV** svals;
    UV*  cm;
  PPCODE:
    cv = sv_2cv(block, &stash, &gv, 0);
    if (cv == Nullcv)
      croak("Not a subroutine reference");
    if (ix == 1 && svk != 0)
      croak("Too many arguments for forperm");

    if (!_validate_int(aTHX_ svn, 0) || (svk != 0 && !_validate_int(aTHX_ svk, 0))) {
      _vcallsub_with_pp( (ix == 0) ? "forcomb" : "forperm" );
      return;
    }

    n = my_svuv(svn);
    k = (svk == 0) ? n : my_svuv(svk);
    if (k > n)
      return;

    New(0, cm, k+1, UV);
    cm[0] = UV_MAX;
    for (i = 0; i < k; i++)
      cm[i] = k-i;

    New(0, svals, n, SV*);
    for (i = 0; i < n; i++) {
      svals[i] = newSVuv(i);
      SvREADONLY_on(svals[i]);
    }

    while (1) {
      { dSP; ENTER; PUSHMARK(SP);                /* Send the values */
        EXTEND(SP, k);
        for (i = 0; i < k; i++) { PUSHs(svals[ cm[k-i-1]-1 ]); }
        PUTBACK; call_sv((SV*)cv, G_VOID|G_DISCARD); LEAVE;
      }
      if (ix == 0) {
        if (cm[0]++ < n)  continue;                /* Increment last value */
        for (i = 1; i < k && cm[i] >= n-i; i++) ;  /* Find next index to incr */
        if (i >= k)  break;                        /* Done! */
        cm[i]++;                                   /* Increment this one */
        while (i-- > 0)  cm[i] = cm[i+1] + 1;      /* Set the rest */
      } else {
        for (j = 1; j < k && cm[j] > cm[j-1]; j++) ;    /* Find last decrease */
        if (j >= k) break;                              /* Done! */
        for (m = 0; cm[j] > cm[m]; m++) ;               /* Find next greater */
        { UV t = cm[j];  cm[j] = cm[m];  cm[m] = t; }   /* Swap */
        for (i = j-1, m = 0;  m < i;  i--, m++)         /* Reverse the end */
          { UV t = cm[i];  cm[i] = cm[m];  cm[m] = t; }
      }
    }
    Safefree(cm);
    for (i = 0; i < n; i++)
      SvREFCNT_dec(svals[i]);
    Safefree(svals);
