/*
 * _garage_tesseract: OCR for garage_rag.extract.tesseract through Tesseract's C API (capi.h).
 *
 * Built into the app's Python as a static built-in module (Modules/Setup.local, see
 * //ext/python), with //ext/tesseract and //ext/leptonica linked in statically: there is no
 * libtesseract dylib to load and no ctypes binding. garage_rag hands it pixels Pillow already
 * decoded, so Leptonica never reads an image file.
 *
 * An Engine is one initialised TessBaseAPI. Its calls are serialised by a lock of its own, and
 * recognition runs with the GIL released, so engines on different threads read in parallel.
 * tests/test_tesseract.py holds it to the same results as the ctypes path.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <tesseract/capi.h>

/* TessPageIteratorLevel's RIL_WORD. */
#define WORD_LEVEL 3

typedef struct {
    PyObject_HEAD
    TessBaseAPI *api;
    PyMutex lock;
} EngineObject;

typedef struct {
    PyTypeObject *engine_type;
} module_state;

PyDoc_STRVAR(version_doc, "version() -> str\n\nThe linked Tesseract's version, e.g. '5.5.3'.");

static PyObject *
version(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    return PyUnicode_FromString(TessVersion());
}

static PyObject *
engine_new(PyTypeObject *type, PyObject *args, PyObject *kwargs)
{
    static char *keywords[] = {"datapath", "language", "page_seg_mode", NULL};
    PyObject *datapath_arg = Py_None;
    const char *language;
    int page_seg_mode;
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "Osi:Engine", keywords, &datapath_arg, &language,
                                     &page_seg_mode)) {
        return NULL;
    }
    PyObject *datapath = NULL;
    if (datapath_arg != Py_None && !PyUnicode_FSConverter(datapath_arg, &datapath)) {
        return NULL;
    }

    EngineObject *self = (EngineObject *)type->tp_alloc(type, 0);
    if (self == NULL) {
        Py_XDECREF(datapath);
        return NULL;
    }
    int rc;
    Py_BEGIN_ALLOW_THREADS
    self->api = TessBaseAPICreate();
    rc = TessBaseAPIInit3(self->api, datapath ? PyBytes_AS_STRING(datapath) : NULL, language);
    if (rc == 0) {
        TessBaseAPISetPageSegMode(self->api, (TessPageSegMode)page_seg_mode);
    }
    Py_END_ALLOW_THREADS
    if (rc != 0) {
        if (datapath != NULL) {
            PyErr_Format(PyExc_RuntimeError, "tesseract could not load '%s' language data from %s", language,
                         PyBytes_AS_STRING(datapath));
        }
        else {
            PyErr_Format(PyExc_RuntimeError,
                         "tesseract could not load '%s' language data from its default tessdata", language);
        }
        Py_XDECREF(datapath);
        Py_DECREF(self);
        return NULL;
    }
    Py_XDECREF(datapath);
    return (PyObject *)self;
}

static void
engine_dealloc(PyObject *op)
{
    EngineObject *self = (EngineObject *)op;
    PyTypeObject *type = Py_TYPE(op);
    if (self->api != NULL) {
        TessBaseAPIDelete(self->api);
    }
    type->tp_free(op);
    Py_DECREF(type);
}

PyDoc_STRVAR(set_variable_doc,
"set_variable(name, value) -> bool\n\nSets a Tesseract parameter; False when it has no such parameter.");

static PyObject *
engine_set_variable(PyObject *op, PyObject *args)
{
    EngineObject *self = (EngineObject *)op;
    const char *name, *value;
    if (!PyArg_ParseTuple(args, "ss:set_variable", &name, &value)) {
        return NULL;
    }
    PyMutex_Lock(&self->lock);
    BOOL ok = TessBaseAPISetVariable(self->api, name, value);
    PyMutex_Unlock(&self->lock);
    return PyBool_FromLong(ok);
}

/* Appends each word under the iterator as (text, confidence). Returns 0, or -1 with an
 * exception set. The engine's lock is held, the GIL too. */
static int
collect_words(TessResultIterator *iterator, PyObject *words)
{
    do {
        char *text = TessResultIteratorGetUTF8Text(iterator, WORD_LEVEL);
        if (text == NULL) {
            continue;
        }
        float confidence = TessResultIteratorConfidence(iterator, WORD_LEVEL);
        PyObject *word = Py_BuildValue("(Nd)", PyUnicode_DecodeUTF8(text, (Py_ssize_t)strlen(text), "replace"),
                                       (double)confidence);
        TessDeleteText(text);
        if (word == NULL) {
            return -1;
        }
        int rc = PyList_Append(words, word);
        Py_DECREF(word);
        if (rc < 0) {
            return -1;
        }
    } while (TessResultIteratorNext(iterator, WORD_LEVEL));
    return 0;
}

PyDoc_STRVAR(words_doc,
"words(pixels, width, height, bytes_per_pixel, bytes_per_line, resolution=0) -> list[tuple[str, float]]\n\n"
"Recognises an 8-bit grey (1 byte per pixel) or RGB (3) image and returns its words with their\n"
"0-100 confidences. A resolution of 0 lets Tesseract estimate one.");

static PyObject *
engine_words(PyObject *op, PyObject *args, PyObject *kwargs)
{
    EngineObject *self = (EngineObject *)op;
    static char *keywords[] = {"pixels", "width", "height", "bytes_per_pixel", "bytes_per_line", "resolution", NULL};
    Py_buffer pixels;
    int width, height, bytes_per_pixel, bytes_per_line, resolution = 0;
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*iiii|i:words", keywords, &pixels, &width, &height,
                                     &bytes_per_pixel, &bytes_per_line, &resolution)) {
        return NULL;
    }
    if (width <= 0 || height <= 0 || bytes_per_pixel <= 0 || bytes_per_line < width * bytes_per_pixel
        || pixels.len < (Py_ssize_t)bytes_per_line * height) {
        PyBuffer_Release(&pixels);
        PyErr_SetString(PyExc_ValueError, "pixels does not hold an image of that size");
        return NULL;
    }

    PyObject *words = PyList_New(0);
    if (words == NULL) {
        PyBuffer_Release(&pixels);
        return NULL;
    }
    int rc;
    TessResultIterator *iterator = NULL;
    PyMutex_Lock(&self->lock);
    Py_BEGIN_ALLOW_THREADS
    TessBaseAPISetImage(self->api, (const unsigned char *)pixels.buf, width, height, bytes_per_pixel,
                        bytes_per_line);
    if (resolution > 0) {
        TessBaseAPISetSourceResolution(self->api, resolution);
    }
    rc = TessBaseAPIRecognize(self->api, NULL);
    if (rc == 0) {
        iterator = TessBaseAPIGetIterator(self->api);
    }
    Py_END_ALLOW_THREADS
    PyBuffer_Release(&pixels);

    int failed = 0;
    if (rc != 0) {
        PyErr_SetString(PyExc_RuntimeError, "tesseract recognition failed");
        failed = 1;
    }
    else if (iterator != NULL) {
        failed = collect_words(iterator, words) < 0;
        TessResultIteratorDelete(iterator);
    }
    TessBaseAPIClear(self->api);
    PyMutex_Unlock(&self->lock);
    if (failed) {
        Py_DECREF(words);
        return NULL;
    }
    return words;
}

static PyMethodDef engine_methods[] = {
    {"set_variable", engine_set_variable, METH_VARARGS, set_variable_doc},
    {"words", (PyCFunction)(void (*)(void))engine_words, METH_VARARGS | METH_KEYWORDS, words_doc},
    {NULL, NULL, 0, NULL},
};

PyDoc_STRVAR(engine_doc,
"Engine(datapath, language, page_seg_mode)\n\n"
"One initialised Tesseract engine: `language`'s data from `datapath` (None: Tesseract's own\n"
"default, or TESSDATA_PREFIX) with the given TessPageSegMode. RuntimeError when the data does\n"
"not load.");

static PyType_Slot engine_slots[] = {
    {Py_tp_new, engine_new},
    {Py_tp_dealloc, engine_dealloc},
    {Py_tp_methods, engine_methods},
    {Py_tp_doc, (void *)engine_doc},
    {0, NULL},
};

static PyType_Spec engine_spec = {
    .name = "_garage_tesseract.Engine",
    .basicsize = sizeof(EngineObject),
    .flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_IMMUTABLETYPE,
    .slots = engine_slots,
};

static PyMethodDef methods[] = {
    {"version", version, METH_NOARGS, version_doc},
    {NULL, NULL, 0, NULL},
};

static int
exec_module(PyObject *module)
{
    module_state *state = PyModule_GetState(module);
    state->engine_type = (PyTypeObject *)PyType_FromModuleAndSpec(module, &engine_spec, NULL);
    if (state->engine_type == NULL) {
        return -1;
    }
    return PyModule_AddType(module, state->engine_type);
}

static int
traverse_module(PyObject *module, visitproc visit, void *arg)
{
    module_state *state = PyModule_GetState(module);
    Py_VISIT(state->engine_type);
    return 0;
}

static int
clear_module(PyObject *module)
{
    module_state *state = PyModule_GetState(module);
    Py_CLEAR(state->engine_type);
    return 0;
}

static void
free_module(void *module)
{
    clear_module((PyObject *)module);
}

static PyModuleDef_Slot slots[] = {
    {Py_mod_exec, exec_module},
#ifdef Py_mod_multiple_interpreters
    {Py_mod_multiple_interpreters, Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED},
#endif
#ifdef Py_GIL_DISABLED
    /* Each Engine serialises its own calls with its lock. */
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
#endif
    {0, NULL},
};

static struct PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_garage_tesseract",
    .m_doc = "OCR through a statically linked Tesseract and Leptonica.",
    .m_size = sizeof(module_state),
    .m_methods = methods,
    .m_slots = slots,
    .m_traverse = traverse_module,
    .m_clear = clear_module,
    .m_free = free_module,
};

PyMODINIT_FUNC
PyInit__garage_tesseract(void)
{
    return PyModuleDef_Init(&module_def);
}
