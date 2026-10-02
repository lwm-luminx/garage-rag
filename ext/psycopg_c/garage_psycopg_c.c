/*
 * Registers psycopg's C implementation as built-in modules.
 *
 * psycopg_c's two extension modules, `pq.c` and `_psycopg.c` (Cython output shipped in its sdist),
 * are compiled into the binary that starts the interpreter, with //ext/postgres's libpq.a linked
 * in statically. Their init functions are renamed at compile time (see BUILD.bazel) and listed
 * here under their dotted names; CPython's BuiltinImporter finds a dotted built-in once the parent
 * package, the sdist's pure-Python `psycopg_c/__init__.py` in site-packages, is imported. psycopg
 * then picks its "c" implementation by itself, so there is no libpq dylib and no ctypes binding.
 */

#include "garage_psycopg_c.h"

#include <Python.h>

PyMODINIT_FUNC GaragePyInit_psycopg_c_pq(void);
PyMODINIT_FUNC GaragePyInit_psycopg_c__psycopg(void);

int GaragePsycopgCRegister(void)
{
    static int registered = 0;
    if (registered) {
        return 0;
    }
    if (PyImport_AppendInittab("psycopg_c.pq", GaragePyInit_psycopg_c_pq) < 0
        || PyImport_AppendInittab("psycopg_c._psycopg", GaragePyInit_psycopg_c__psycopg) < 0) {
        return -1;
    }
    registered = 1;
    return 0;
}
