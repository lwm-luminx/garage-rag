/*
 * psycopg's C implementation (psycopg_c), built into the process rather than imported from a
 * .so. See garage_psycopg_c.c.
 */

#ifndef GARAGE_PSYCOPG_C_H
#define GARAGE_PSYCOPG_C_H

#ifdef __cplusplus
extern "C" {
#endif

/// Adds `psycopg_c.pq` and `psycopg_c._psycopg` to the interpreter's built-in modules. Call it
/// once, before the interpreter starts (`PyImport_AppendInittab`). Returns 0, or -1 when CPython
/// could not grow its table.
int GaragePsycopgCRegister(void);

#ifdef __cplusplus
}
#endif

#endif /* GARAGE_PSYCOPG_C_H */
