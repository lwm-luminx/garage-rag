//
//  GaragePythonEmbed.c
//  PythonXPCService
//
//  Implements isolated interpreter start-up using the PyConfig API documented at
//  https://docs.python.org/3/c-api/init_config.html ("Isolated Configuration") and
//  https://docs.python.org/3/c-api/interp-lifecycle.html.
//

#include "GaragePythonEmbed.h"

#include <Python.h>

#include "garage_psycopg_c.h"

#include <stdio.h>
#include <string.h>

static void _GarageCopyError(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    if (message == NULL) {
        message = "unknown error";
    }
    strncpy(buffer, message, size - 1);
    buffer[size - 1] = '\0';
}

static void _GarageCopyStatusError(char *buffer, size_t size, PyStatus status) {
    if (buffer == NULL || size == 0) {
        return;
    }
    const char *func = status.func ? status.func : "Py_InitializeFromConfig";
    const char *msg = status.err_msg ? status.err_msg : "unknown error";
    snprintf(buffer, size, "%s: %s (exitcode=%d)", func, msg, status.exitcode);
}

GaragePythonEmbedOptions GaragePythonEmbedOptionsDefault(void) {
    GaragePythonEmbedOptions options;
    memset(&options, 0, sizeof(options));
    options.disableBytecodeWriting = true;
    options.skipSignalHandlers = true;
    options.importSite = true;
    options.releaseGILAfterInit = true;
    options.verbose = false;
    return options;
}

GaragePythonEmbedResult GaragePythonEmbedInitialize(const GaragePythonEmbedOptions *options,
                                                    char *errorBuffer,
                                                    size_t errorBufferSize) {
    if (errorBuffer != NULL && errorBufferSize > 0) {
        errorBuffer[0] = '\0';
    }
    if (options == NULL) {
        _GarageCopyError(errorBuffer, errorBufferSize, "options must not be NULL");
        return GaragePythonEmbedResultInvalidArgument;
    }
    if (Py_IsInitialized()) {
        _GarageCopyError(errorBuffer, errorBufferSize, "interpreter is already initialized");
        return GaragePythonEmbedResultAlreadyInitialized;
    }
    if (options->home == NULL || options->home[0] == '\0') {
        _GarageCopyError(errorBuffer, errorBufferSize, "options->home must be set to the bundled python directory");
        return GaragePythonEmbedResultInvalidArgument;
    }

    // psycopg's C implementation is linked into this framework, with libpq (//ext/psycopg_c). Its
    // modules join the built-in table here, which CPython reads when the interpreter starts.
    if (GaragePsycopgCRegister() < 0) {
        _GarageCopyError(errorBuffer, errorBufferSize, "could not register psycopg_c's built-in modules");
        return GaragePythonEmbedResultConfigError;
    }

    PyStatus status;
    PyConfig config;

    // UTF-8 mode (PEP 540). The isolated pre-configuration leaves it off, so a
    // process the app launches without LANG/LC_ALL gets an ASCII locale, and
    // sys.stdout then raises UnicodeEncodeError on the first non-ASCII character
    // it prints (a citation's trailing "\u2026" in `garage ask` was the first to
    // hit it). Every string this interpreter exchanges with the app is UTF-8
    // anyway, so pin stdio, open() and the filesystem encoding to it.
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
        return GaragePythonEmbedResultConfigError;
    }

    // Isolated configuration: ignore PYTHON* environment variables, the current
    // working directory, user site-packages and command line arguments so the
    // embedded interpreter only ever sees the environment shipped in the bundle.
    PyConfig_InitIsolatedConfig(&config);

    config.isolated = 1;
    config.use_environment = 0;
    config.user_site_directory = 0;
    config.safe_path = 1;
    config.parse_argv = 0;
    config.configure_c_stdio = 0;
    config.buffered_stdio = 0;
    config.site_import = options->importSite ? 1 : 0;
    config.install_signal_handlers = options->skipSignalHandlers ? 0 : 1;
    config.write_bytecode = options->disableBytecodeWriting ? 0 : 1;
    config.pathconfig_warnings = options->verbose ? 1 : 0;
    config.verbose = options->verbose ? 1 : 0;

    status = PyConfig_SetBytesString(&config, &config.home, options->home);
    if (PyStatus_Exception(status)) {
        _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
        PyConfig_Clear(&config);
        return GaragePythonEmbedResultConfigError;
    }

    const char *programName = options->programName ? options->programName : "python3";
    status = PyConfig_SetBytesString(&config, &config.program_name, programName);
    if (PyStatus_Exception(status)) {
        _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
        PyConfig_Clear(&config);
        return GaragePythonEmbedResultConfigError;
    }

    // Per the "Python Path Configuration" docs: when module_search_paths_set is 1
    // the interpreter uses module_search_paths verbatim as sys.path instead of
    // running its landmark based search (getpath.py).
    config.module_search_paths_set = 1;

    if (options->stdlibDir != NULL && options->stdlibDir[0] != '\0') {
        status = PyConfig_SetBytesString(&config, &config.stdlib_dir, options->stdlibDir);
        if (PyStatus_Exception(status)) {
            _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
            PyConfig_Clear(&config);
            return GaragePythonEmbedResultConfigError;
        }
        wchar_t *wide = Py_DecodeLocale(options->stdlibDir, NULL);
        if (wide == NULL) {
            _GarageCopyError(errorBuffer, errorBufferSize, "failed to decode stdlibDir");
            PyConfig_Clear(&config);
            return GaragePythonEmbedResultConfigError;
        }
        status = PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) {
            _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
            PyConfig_Clear(&config);
            return GaragePythonEmbedResultConfigError;
        }
    }

    if (options->platStdlibDir != NULL && options->platStdlibDir[0] != '\0') {
        wchar_t *wide = Py_DecodeLocale(options->platStdlibDir, NULL);
        if (wide == NULL) {
            _GarageCopyError(errorBuffer, errorBufferSize, "failed to decode platStdlibDir");
            PyConfig_Clear(&config);
            return GaragePythonEmbedResultConfigError;
        }
        status = PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) {
            _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
            PyConfig_Clear(&config);
            return GaragePythonEmbedResultConfigError;
        }
    }

    if (options->extraSearchPaths != NULL) {
        for (const char *const *cursor = options->extraSearchPaths; *cursor != NULL; cursor++) {
            if ((*cursor)[0] == '\0') {
                continue;
            }
            wchar_t *wide = Py_DecodeLocale(*cursor, NULL);
            if (wide == NULL) {
                _GarageCopyError(errorBuffer, errorBufferSize, "failed to decode extra search path");
                PyConfig_Clear(&config);
                return GaragePythonEmbedResultConfigError;
            }
            status = PyWideStringList_Append(&config.module_search_paths, wide);
            PyMem_RawFree(wide);
            if (PyStatus_Exception(status)) {
                _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
                PyConfig_Clear(&config);
                return GaragePythonEmbedResultConfigError;
            }
        }
    }

    // Read the remaining (computed) fields so that prefix/exec_prefix/executable
    // get populated from `home` before the interpreter starts.
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) {
        _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
        PyConfig_Clear(&config);
        return GaragePythonEmbedResultConfigError;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        _GarageCopyStatusError(errorBuffer, errorBufferSize, status);
        if (PyStatus_IsExit(status)) {
            return GaragePythonEmbedResultExit;
        }
        return GaragePythonEmbedResultInitError;
    }

    if (options->releaseGILAfterInit) {
        // The initializing thread owns the GIL after Py_InitializeFromConfig.
        // Release it so that arbitrary host threads can take it with
        // PyGILState_Ensure() and Python-created threads can make progress.
        (void)PyEval_SaveThread();
    }

    return GaragePythonEmbedResultOK;
}

bool GaragePythonEmbedIsInitialized(void) {
    return Py_IsInitialized() != 0;
}

int GaragePythonEmbedFinalize(void) {
    if (!Py_IsInitialized()) {
        return 0;
    }
    (void)PyGILState_Ensure();
    return Py_FinalizeEx();
}

int GaragePythonEmbedAcquireGIL(void) {
    return (int)PyGILState_Ensure();
}

void GaragePythonEmbedReleaseGIL(int token) {
    PyGILState_Release((PyGILState_STATE)token);
}

int GaragePythonEmbedRunSimpleString(const char *source) {
    if (source == NULL) {
        return -1;
    }
    return PyRun_SimpleString(source);
}

const char *GaragePythonEmbedCompiledVersion(void) {
    return PY_VERSION;
}

const char *GaragePythonEmbedRuntimeVersion(void) {
    return Py_GetVersion();
}
