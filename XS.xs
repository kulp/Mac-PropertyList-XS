#include <assert.h>
#include <search.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

// for base64 decoding
static unsigned char alphabet[64] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char decoder[256];

enum ctx { S_EMPTY, S_TOP, S_FREE, S_DICT, S_ARRAY, S_KEY, S_TEXT };

static const char *context_names[] = {
#define _R(X) [S_##X] = #X
    _R(EMPTY),
    _R(TOP),
    _R(FREE),
    _R(DICT),
    _R(ARRAY),
    _R(KEY),
    _R(TEXT),
#undef _R
};

struct state {
    SV *parser;
    SV *accum;
    // TODO keep everything in the stack to reduce copying
    struct node {
        enum ctx context;
        SV *key;
        SV *val;
    } base;
    struct stack {
        struct node node;
        struct stack *next;
    } *stack;
};

// TODO support multiple states using a tree indexed by pointer
//static struct state _st = { .base.context = S_EMPTY };
//static struct state *st = &_st;

void *statetree;

#define countof(X) (sizeof (X) / sizeof (X)[0])

/// TODO use our own ::XS namespace
#define PACKAGE_PREFIX "Mac::PropertyList::SAX::"
// long enough to cover any type name
#define TYPE_FILLER    "XXXXXXXX"

#define COMPLEX_TYPES \
    _R(dict) \
    _R(array)

#define NUMERICAL_TYPES \
    _R(real) \
    _R(integer) \
    _R(true) \
    _R(false)

#define SIMPLE_TYPES \
    _R(data) \
    _R(date) \
    _R(string) \
    NUMERICAL_TYPES

#define ALL_TYPES \
    COMPLEX_TYPES \
    SIMPLE_TYPES

enum type {
#define _R(X) T_##X,
    ALL_TYPES
#undef _R
    T_max
};

#define _R(X) [T_##X] = #X,
static const char *      ALL_types[] = { ALL_TYPES       };
static const char *   SIMPLE_types[] = { SIMPLE_TYPES    };
static const char *NUMERICAL_types[] = { NUMERICAL_TYPES };
static const char *  COMPLEX_types[] = { COMPLEX_TYPES   };
#undef _R

enum hash_value {
#define _R(Hash,Key) HASH_FOR_##Key = Hash,

_R(  0, real    )
_R(  3, key     )
_R(  4, dict    )
_R(  5, true    )
_R(  9, date    )
_R( 10, integer )
_R( 14, data    )
_R( 15, string  )
_R( 19, false   )
_R( 20, array   )
_R( 25, plist   )

#undef _R
};

static inline unsigned int hash(register const char *str)
{
    static const unsigned char asso_values[] = {
         0, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 10, 26, 26,
         4,  5,  9, 26, 26,  5, 26,  3,  0, 26,
        26, 26, 15, 26,  0, 10,  0, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26
    };

    return asso_values[(unsigned char)str[3]] + asso_values[(unsigned char)str[0]];
}

static int _find_parser(const void *a, const void *b)
{
    assert(a != NULL);
    assert(b != NULL);

    const struct state *x = a;
    const struct state *y = b;

    assert(x->parser != NULL);
    assert(y->parser != NULL);

    return PTR2IV(SvRV(x->parser)) -
           PTR2IV(SvRV(y->parser));
}

static struct state* state_for_parser(SV *parser)
{
    struct state st = { .parser = parser };
    struct state **result = tfind(&st, &statetree, _find_parser);
    if (*result == NULL)
        croak("Failed to look up state object by parser argument");
    return *result;
}

static enum ctx context_for_name(const char *name)
{
    static const enum ctx lookup[] = {
        [HASH_FOR_dict ] = S_DICT,
        [HASH_FOR_array] = S_ARRAY,
    };

    return lookup[hash(name)];
}

static inline int is_ALL_type(const char *name)
{
    register int o = hash(name);
    switch (o) {
#define _R(X) case HASH_FOR_##X:
        ALL_TYPES
#undef _R
            return 1;
        default:
            return 0;
    }
}

static inline int is_COMPLEX_type(const char *name)
{
    register int o = hash(name);
    switch (o) {
#define _R(X) case HASH_FOR_##X:
        COMPLEX_TYPES
#undef _R
            return 1;
        default:
            return 0;
    }
}

static inline int is_SIMPLE_type(const char *name)
{
    register int o = hash(name);
    switch (o) {
#define _R(X) case HASH_FOR_##X:
        SIMPLE_TYPES
#undef _R
            return 1;
        default:
            return 0;
    }
}

MODULE = Mac::PropertyList::XS		PACKAGE = Mac::PropertyList::XS		

PROTOTYPES: ENABLE

void
handle_start(SV *expat, SV *element, ...)
    CODE:
        struct state *st = state_for_parser(expat);
        const char *name = SvPVX(element);
        if (st->base.context == S_EMPTY && hash(name) == HASH_FOR_plist) {
            st->base.context = S_TOP;
        } else if (st->base.context == S_TOP || hash(name) == HASH_FOR_key || is_ALL_type(name)) {
            struct stack *old = st->stack;
            Newxz(st->stack, 1, struct stack);
            st->stack->node = st->base;
            st->stack->next = old;

            if (is_COMPLEX_type(name)) {
                char temp[] = PACKAGE_PREFIX TYPE_FILLER;
                strcpy(&temp[sizeof PACKAGE_PREFIX - 1], name);

                PUSHMARK(SP);
                XPUSHs(sv_2mortal(newSVpv(temp, 0)));
                PUTBACK;
                int count = call_method("new", G_SCALAR);
                SPAGAIN;
                if (count != 1) croak("Failed new() call");

                st->base.val = POPs;
                SvREFCNT_inc(st->base.val);
                st->base.context = context_for_name(name);
                //SvREFCNT_dec(st->base.key);
                st->base.key = NULL;
            } else if (is_SIMPLE_type(name)) {
                st->base.context = S_TEXT;
            } else if (hash(name) == HASH_FOR_key) {
                if (st->base.context == S_DICT) {
                    st->base.context = S_KEY;
                } else {
                    croak("<key/> in improper context '%s'", context_names[st->base.context]);
                }
            } else {
                croak("Top-level element '%s' in plist is not recognized", name);
            }
        } else {
            croak("Received invalid start element '%s'", name);
        }

void
handle_end(SV *expat, SV *element)
    CODE:
        struct state *st = state_for_parser(expat);
        const char *name = SvPVX(element);
        if (hash(name) != HASH_FOR_plist) { // discard plist element
            struct node *elt = &st->stack->node;
            struct stack *temp = st->stack;
            st->stack = st->stack->next;

            SV *val = st->base.val;
            st->base = *elt;

            if (is_SIMPLE_type(name)) {
                char pv[] = PACKAGE_PREFIX TYPE_FILLER;
                strcpy(&pv[sizeof PACKAGE_PREFIX - 1], name);

                PUSHMARK(SP);
                XPUSHs(sv_2mortal(newSVpv(pv, 0)));
                if (st->accum) {
                    if (hash(name) == HASH_FOR_data) {
                        // base64 decode
                        // from http://ftp.riken.jp/net/mail/vm/base64-decode.c
                        int i, j = 0, char_count = 0, bits = 0, total = 0;
                        size_t len;
                        const char *what = SvPV(st->accum, len);
                        char out[len];
                        for (i = 0; what[i] != 0; i++) {
                            unsigned char c = what[i];
                            if (c == '=') break;
                            // maybe handle bogus data better ?
                            bits += decoder[c];
                            char_count++;
                            if (char_count == 4) {
                                out[j++] = bits >> 16;
                                out[j++] = (bits >> 8) & 0xff;
                                out[j++] = bits & 0xff;
                                bits = 0;
                                char_count = 0;
                                total++;
                            } else {
                                bits <<= 6;
                            }
                        }

                        XPUSHs(sv_2mortal(newSVpvn(out, total)));
                    } else {
                        XPUSHs(sv_2mortal(st->accum));
                    }
                } else {
                    XPUSHs(sv_2mortal(newSVpv("", 0)));
                }

                PUTBACK;
                int count = call_method("new", G_SCALAR);
                SPAGAIN;
                if (count != 1) croak("Failed new() call");

                val = POPs;
                SvREFCNT_inc(val);

                //SvREFCNT_dec(st->accum);
                st->accum = NULL;
            } else if (hash(name) == HASH_FOR_key) {
                SvREFCNT_dec(st->base.key);
                st->base.key = st->accum;
                st->accum = NULL;
                Safefree(temp);
                return;
            }

            switch (st->base.context) {
                case S_DICT:
                    hv_store_ent((HV*)SvRV(st->base.val), st->base.key, val, 0);
                    break;
                case S_ARRAY:
                    av_push((AV*)SvRV(st->base.val), val);
                    break;
                case S_TOP:
                    st->base.val = val;
                    break;
                default:
                    croak("Bad context '%s'", context_names[st->base.context]);
            }

            Safefree(temp);
        }

void
handle_char(SV *expat, SV *string)
    CODE:
        struct state *st = state_for_parser(expat);
        if (st->base.context == S_TEXT || st->base.context == S_KEY) {
            if (!st->accum)
                st->accum = newSVpvn("", 0);
            sv_catsv(st->accum, string);
        }

void
handle_init(SV *expat)
    CODE:
        struct state *st;
        Newxz(st, 1, struct state);
        st->parser = expat;
        // this is fragile : what if the expat object moves ?
        tsearch(st, &statetree, _find_parser);

        if (!decoder[0]) {
            int i;
            for (i = (sizeof alphabet) - 1; i >= 0 ; i--)
                decoder[alphabet[i]] = i;
        }


SV *
handle_final(SV *expat)
    CODE:
        struct state *st = state_for_parser(expat);
        tdelete(st, &statetree, _find_parser);
        RETVAL = st->base.val;
        while (st->stack) {
            struct stack *temp = st->stack;
            st->stack = st->stack->next;
            Safefree(temp);
        }
        Safefree(st);
    OUTPUT:
        RETVAL

INCLUDE: const-xs.inc

