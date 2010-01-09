#include <search.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

enum ctx { S_EMPTY, S_TOP, S_FREE, S_DICT, S_ARRAY, S_KEY, S_TEXT };

struct state {
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
static struct state _st = {
    .base.context = S_EMPTY,
};
static struct state *st = &_st;

#define countof(X) (sizeof (X) / sizeof (X)[0])

#define PACKAGE_PREFIX "Mac::PropertyList::"

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

static int _str_cmp(const void *a, const void *b)
{
    return *(char**)b ? strcmp(a, *(char **)b) : -1;
}

static enum ctx context_for_name(const char *name)
{
    size_t count = countof(ALL_types);
    // TODO use gperf or some fast hash function to look up context
    const char **which = lfind(name, ALL_types, &count, sizeof ALL_types[0], _str_cmp);
    if (which == NULL)
        return -1;
    return which - ALL_types;
}

#define _R(X) \
    static int is_##X##_type(const char *name) \
    { \
        size_t count = countof(X##_types); \
        return lfind(name, X##_types, &count, sizeof X##_types[0], _str_cmp) != NULL; \
    }

_R(ALL)
_R(SIMPLE)
_R(NUMERICAL)
_R(COMPLEX)

#undef _R

MODULE = Mac::PropertyList::XS		PACKAGE = Mac::PropertyList::XS		

PROTOTYPES: ENABLE

void
handle_start(SV *expat, SV *element, ...)
    CODE:
        const char *name = SvPVX(element);
        if (st->base.context == S_EMPTY && strcmp(name, "plist") == 0) {
            st->base.context = S_TOP;
        } else if (st->base.context == S_TOP || strcmp(name, "key") == 0 || is_ALL_type(name)) {
            struct stack *old = st->stack;
            //st->stack = malloc(sizeof *st->stack);
            Newxz(st->stack, 1, struct stack);
            st->stack->node = st->base;
            st->stack->next = old;

            if (is_COMPLEX_type(name)) {
                // TODO figure out the most efficient way to compute this name
                /// TODO use our own ::XS namespace
                char temp[] = PACKAGE_PREFIX "XXXXXX";
                strcpy(&temp[sizeof PACKAGE_PREFIX - 1], name);
                /*
                SV *cname = newSVpvn(temp, sizeof temp + sizeof "XXXXX" + sizeof "->new");
                sv_catsv(cname, element);
                sv_catpv(cname, "->new");
                */

                // TODO do this without eval()
                PUSHMARK(SP);
                XPUSHs(sv_2mortal(newSVpv(temp, 0)));
                PUTBACK;
                int count = call_method("new", G_SCALAR);
                SPAGAIN;
                if (count != 1) croak("Failed new() call");

                //st->base.val = eval_pv(SvPV_nolen(cname), 0);
                st->base.val = POPs;
                SvREFCNT_inc(st->base.val);
                st->base.context = context_for_name(name);
                SvREFCNT_dec(st->base.key);
            } else if (is_SIMPLE_type(name)) {
                st->base.context = S_TEXT;
            } else if (strcmp(name, "key")) {
                if (st->base.context == S_DICT) {
                    st->base.context = S_KEY;
                } else {
                    croak("<key/> in improper context %s'", ALL_types[st->base.context]);
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
        const char *name = SvPVX(element);
        if (strcmp(name, "plist")) { // discard plist element
            struct node *elt = &st->stack->node;
            st->stack = st->stack->next;

            SV *val = st->base.val;
            st->base = *elt;

            if (is_SIMPLE_type(name)) {
                char pv[] = PACKAGE_PREFIX "XXXXXX";
                strcpy(&pv[sizeof PACKAGE_PREFIX - 1], name);

                PUSHMARK(SP);
                if (st->accum) {
                    if (strcmp(name, "data") == 0) {
                        ; // TODO mime64
                    } else {
                        XPUSHs(st->accum);
                    }
                } else {
                    XPUSHs(sv_2mortal(newSVpv("", 0)));
                }

                XPUSHs(sv_2mortal(newSVpv(pv, 0)));
                PUTBACK;
                int count = call_method("new", G_SCALAR);
                SPAGAIN;
                if (count != 1) croak("Failed new() call");

                val = POPs;
                SvREFCNT_inc(val);
            } else if (strcmp(name, "key") == 0) {
                st->base.key = st->accum;
                st->accum = NULL;
                return;
            }

            switch (st->base.context) {
                STRLEN len;
                char *k;
                case S_DICT:
                    k = SvPV(st->base.key, len);
                    hv_store((HV*)st->base.val, k, len, val, 0);
                    break;
                case S_ARRAY:
                    av_push((AV*)st->base.val, val);
                    break;
                case S_TOP:
                    st->base.val = val;
                    break;
                default:
                    croak("Bad context '%s'", ALL_types[st->base.context]);
            }
        }

void
handle_char(SV *expat, SV *string)
    CODE:
        if (st->base.context == S_TEXT || st->base.context == S_KEY)
            sv_catsv(st->accum, string);

INCLUDE: const-xs.inc
