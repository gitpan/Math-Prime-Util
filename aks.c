#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/*
 * The AKS v6 algorithm, for native integers, where n < 2^(wordbits/2)-1.
 * Hence on 64-bit machines this works for n < 4294967295, because we do
 *   r = (r + a * b) % n
 * where r, a, and b are mod n.  This could be extended to a full word by
 * using a mulmod function (like factor.c has), but it's easier to go to
 * GMP at that point, which also lets one do r or 2r modulos instead of r*r.
 *
 * Copyright 2012, Dana Jacobsen.
 */

#define SQRTN_SHORTCUT 1
#define VERBOSE 0

#include "ptypes.h"
#include "util.h"
#include "sieve.h"
#include "factor.h"
#include "cache.h"

#define addmod(n,a,m) ((((m)-(n)) > (a))  ?  ((n)+(a))  :  ((n)+(a)-(m)))

static UV log2floor(UV n) {
  UV log2n = 0;
  while (n >>= 1)
    log2n++;
  return log2n;
}

/* See Bach and Sorenson (1993) for much better algorithm */
static int is_perfect_power(UV x) {
  UV b, last;
  if ((x & (x-1)) == 0)  return 1;          /* powers of 2    */
  b = sqrt(x); if (b*b == x)  return 1;     /* perfect square */
  b = cbrt(x); if (b*b*b == x)  return 1;   /* perfect cube   */
  last = log2floor(x) + 1;
  for (b = 5; b < last; b = _XS_next_prime(b)) {
    UV root = pow(x, 1.0 / (double)b);
    if (pow(root, b) == x)  return 1;
  }
  return 0;
}

static UV order(UV r, UV n, UV limit) {
  UV j;
  UV t = 1;
  for (j = 1; j <= limit; j++) {
    t = (t * n) % r;
    if (t == 1)
      break;
  }
  return j;
}

static void poly_print(UV* poly, UV r)
{
  int i;
  for (i = r-1; i >= 1; i--) {
    if (poly[i] != 0)
      printf("%lux^%d + ", poly[i], i);
  }
  if (poly[0] != 0) printf("%lu", poly[0]);
  printf("\n");
}

static void poly_mod_mul(UV* px, UV* py, UV* res, UV r, UV mod)
{
  int i, j;
  UV pxi, pyj, rindex;

  memset(res, 0, r * sizeof(UV));
  for (i = 0; i < r; i++) {
    pxi = px[i];
    if (pxi == 0)  continue;
    for (j = 0; j < r; j++) {
      pyj = py[j];
      if (pyj == 0)  continue;
      rindex = (i+j) < r ? i+j : i+j-r; /* (i+j) % r */
      res[rindex] = (res[rindex] + (pxi*pyj) ) % mod;
    }
  }
  memcpy(px, res, r * sizeof(UV)); /* put result in px */
}
static void poly_mod_sqr(UV* px, UV* res, UV r, UV mod)
{
  int d, s;
  UV sum, rindex;
  UV degree = r-1;

  /* we sum a max of r*mod*mod between modulos */
  if (mod > sqrt(UV_MAX/r))
    return poly_mod_mul(px, px, res, r, mod);

  memset(res, 0, r * sizeof(UV)); /* zero out sums */
  for (d = 0; d <= 2*degree; d++) {
    sum = 0;
    for (s = (d <= degree) ? 0 : d-degree; s <= (d/2); s++) {
      UV c = px[s];
      sum += (s*2 == d) ? c*c : 2*c * px[d-s];
    }
    rindex = (d < r) ? d : d-r;  /* d % r */
    res[rindex] = (res[rindex] + sum) % mod;
  }
  memcpy(px, res, r * sizeof(UV)); /* put result in px */
}

static UV* poly_mod_pow(UV* pn, UV power, UV r, UV mod)
{
  UV* res;
  UV* temp;

  Newz(0, res, r, UV);
  New(0, temp, r, UV);
  if ( (res == 0) || (temp == 0) )
    croak("Couldn't allocate space for polynomial of degree %lu\n", r);

  res[0] = 1;

  while (power) {
    if (power & 1)  poly_mod_mul(res, pn, temp, r, mod);
    power >>= 1;
    if (power)      poly_mod_sqr(pn, temp, r, mod);
  }
  Safefree(temp);
  return res;
}

static int test_anr(UV a, UV n, UV r)
{
  UV* pn;
  UV* res;
  int i;
  int retval = 1;

  Newz(0, pn, r, UV);
  if (pn == 0)
    croak("Couldn't allocate space for polynomial of degree %lu\n", r);
  a %= r;
  pn[0] = a;
  pn[1] = 1;
  res = poly_mod_pow(pn, n, r, n);
  res[n % r] = addmod(res[n % r], n - 1, n);
  res[0]     = addmod(res[0],     n - a, n);

  for (i = 0; i < r; i++)
    if (res[i] != 0)
      retval = 0;
  Safefree(res);
  Safefree(pn);
  return retval;
}

int _XS_is_aks_prime(UV n)
{
  UV sqrtn, limit, r, rlimit, a;
  double log2n;

  /* Check for overflow */
#if BITS_PER_WORD == 32
  if (n >= UVCONST(65535))
#else
  if (n >= UVCONST(4294967295))
#endif
    croak("aks(%"UVuf") overflow", n);

  if (n < 2)
    return 0;
  if (n == 2)
    return 1;

  if (is_perfect_power(n))
    return 0;

  sqrtn = sqrt(n);
  log2n = log(n) / log(2);   /* C99 has a log2() function */
  limit = (UV) floor(log2n * log2n);

  if (VERBOSE) { printf("limit is %lu\n", limit); }

  for (r = 2; r < n; r++) {
    if ((n % r) == 0)
      return 0;
#if SQRTN_SHORTCUT
    if (r > sqrtn)
      return 1;
#endif
    if (order(r, n, limit) > limit)
      break;
  }

  if (r >= n)
    return 1;

  rlimit = (UV) floor(sqrt(r-1) * log2n);

  if (VERBOSE) { printf("r = %lu  rlimit = %lu\n", r, rlimit); }

  for (a = 1; a <= rlimit; a++) {
    if (! test_anr(a, n, r) )
      return 0;
    if (VERBOSE) { printf("."); fflush(stdout); }
  }
  if (VERBOSE) { printf("\n"); }
  return 1;
}
