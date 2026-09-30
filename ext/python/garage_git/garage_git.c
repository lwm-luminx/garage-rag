/*
 * _garage_git: the git history garage_rag.attribute.git reads, through libgit2.
 *
 * Built into the app's Python as a static built-in module (Modules/Setup.local, see
 * //ext/python), with //ext/libgit2 linked in statically: nothing is loaded at run time and
 * no git command is run. Read-only and local: nothing here fetches, clones, pushes or
 * connects anywhere, and the libgit2 it links has no HTTPS or SSH transport.
 *
 * commit_paths() is what `git log --no-merges --no-renames --name-only --format=%aN%x1f%aE`
 * prints. tests/test_git_history.py holds it to that.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <git2.h>

static PyObject *GitError;

/* Raises GitError for a failed libgit2 call and returns NULL. */
static PyObject *
raise_git_error(int rc, const char *what)
{
    const git_error *error = git_error_last();
    if (error != NULL && error->message != NULL && error->message[0] != '\0') {
        PyErr_Format(GitError, "%s: %s", what, error->message);
    }
    else {
        PyErr_Format(GitError, "%s: error %d", what, rc);
    }
    return NULL;
}

static PyObject *
decode(const char *text)
{
    if (text == NULL) {
        return PyUnicode_FromString("");
    }
    return PyUnicode_DecodeUTF8(text, (Py_ssize_t)strlen(text), "replace");
}

/* Opens the repository at a path-like argument. Returns 0, or -1 with an exception set. */
static int
open_repository(PyObject *path, git_repository **repo)
{
    PyObject *encoded = NULL;
    if (!PyUnicode_FSConverter(path, &encoded)) {
        return -1;
    }
    int rc;
    Py_BEGIN_ALLOW_THREADS
    rc = git_repository_open(repo, PyBytes_AS_STRING(encoded));
    Py_END_ALLOW_THREADS
    if (rc < 0) {
        raise_git_error(rc, PyBytes_AS_STRING(encoded));
        Py_DECREF(encoded);
        return -1;
    }
    Py_DECREF(encoded);
    return 0;
}

PyDoc_STRVAR(version_doc, "version() -> str\n\nThe linked libgit2's version, e.g. '1.9.7'.");

static PyObject *
version(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    int major, minor, patch;
    if (git_libgit2_version(&major, &minor, &patch) < 0) {
        return raise_git_error(-1, "version");
    }
    return PyUnicode_FromFormat("%d.%d.%d", major, minor, patch);
}

PyDoc_STRVAR(features_doc,
"features() -> int\n\nThe linked libgit2's GIT_FEATURE_* flags (threads, https, ssh, nsec).");

static PyObject *
features(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    return PyLong_FromLong(git_libgit2_features());
}

PyDoc_STRVAR(remote_url_doc,
"remote_url(path, name='origin') -> str | None\n\n"
"The remote's configured URL, as `git remote get-url` prints it, or None when the\n"
"repository has no such remote. A config lookup; it connects nowhere.");

static PyObject *
remote_url(PyObject *module, PyObject *args, PyObject *kwargs)
{
    static char *keywords[] = {"path", "name", NULL};
    PyObject *path;
    const char *name = "origin";
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "O|s:remote_url", keywords, &path, &name)) {
        return NULL;
    }
    git_repository *repo = NULL;
    if (open_repository(path, &repo) < 0) {
        return NULL;
    }
    git_remote *remote = NULL;
    PyObject *result = NULL;
    int rc = git_remote_lookup(&remote, repo, name);
    if (rc == GIT_ENOTFOUND || rc == GIT_EINVALIDSPEC) {
        result = Py_NewRef(Py_None);
    }
    else if (rc < 0) {
        raise_git_error(rc, "remote");
    }
    else {
        const char *url = git_remote_url(remote);
        result = (url != NULL && url[0] != '\0') ? decode(url) : Py_NewRef(Py_None);
        git_remote_free(remote);
    }
    git_repository_free(repo);
    return result;
}

PyDoc_STRVAR(index_entry_count_doc,
"index_entry_count(path) -> int\n\nEntries in the repository's index: the tracked files `git ls-files` lists.");

static PyObject *
index_entry_count(PyObject *module, PyObject *path)
{
    git_repository *repo = NULL;
    if (open_repository(path, &repo) < 0) {
        return NULL;
    }
    git_index *index = NULL;
    int rc = git_repository_index(&index, repo);
    PyObject *result;
    if (rc < 0) {
        result = raise_git_error(rc, "index");
    }
    else {
        result = PyLong_FromSize_t(git_index_entrycount(index));
        git_index_free(index);
    }
    git_repository_free(repo);
    return result;
}

/*
 * The paths one commit touched, against its first parent (or against nothing, for a root
 * commit), with no rename detection: libgit2 detects renames only when asked
 * (git_diff_find_similar). Returns a new list, or NULL with an exception set.
 */
static PyObject *
changed_paths(git_repository *repo, git_commit *commit, unsigned int parents)
{
    git_tree *new_tree = NULL, *old_tree = NULL;
    git_commit *parent = NULL;
    git_diff *diff = NULL;
    PyObject *paths = NULL;
    const char *failed = NULL;
    int rc;

    Py_BEGIN_ALLOW_THREADS
    rc = git_commit_tree(&new_tree, commit);
    if (rc < 0) {
        failed = "tree";
    }
    else if (parents == 1 && (rc = git_commit_parent(&parent, commit, 0)) < 0) {
        failed = "parent";
    }
    else if (parents == 1 && (rc = git_commit_tree(&old_tree, parent)) < 0) {
        failed = "parent tree";
    }
    else if ((rc = git_diff_tree_to_tree(&diff, repo, old_tree, new_tree, NULL)) < 0) {
        failed = "diff";
    }
    Py_END_ALLOW_THREADS

    if (failed != NULL) {
        raise_git_error(rc, failed);
        goto done;
    }
    size_t count = git_diff_num_deltas(diff);
    paths = PyList_New((Py_ssize_t)count);
    if (paths == NULL) {
        goto done;
    }
    for (size_t i = 0; i < count; i++) {
        const git_diff_delta *delta = git_diff_get_delta(diff, i);
        const char *path = delta->new_file.path != NULL ? delta->new_file.path : delta->old_file.path;
        PyObject *item = decode(path);
        if (item == NULL) {
            Py_CLEAR(paths);
            goto done;
        }
        PyList_SET_ITEM(paths, (Py_ssize_t)i, item);
    }

done:
    git_diff_free(diff);
    git_tree_free(old_tree);
    git_commit_free(parent);
    git_tree_free(new_tree);
    return paths;
}

PyDoc_STRVAR(commit_paths_doc,
"commit_paths(path, max_commits=None) -> list[tuple[str, str, list[str]]]\n\n"
"(author name, author email, touched paths) for each commit reachable from HEAD, as\n"
"`git log --no-merges --no-renames --name-only --format=%aN%x1f%aE` prints them: newest\n"
"first, merges skipped, .mailmap applied to the author. max_commits counts the commits\n"
"returned, as --max-count does. An unborn HEAD gives an empty list.");

static PyObject *
commit_paths(PyObject *module, PyObject *args, PyObject *kwargs)
{
    static char *keywords[] = {"path", "max_commits", NULL};
    PyObject *path;
    PyObject *max_arg = Py_None;
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "O|O:commit_paths", keywords, &path, &max_arg)) {
        return NULL;
    }
    Py_ssize_t max_commits = -1;
    if (max_arg != Py_None) {
        max_commits = PyLong_AsSsize_t(max_arg);
        if (max_commits == -1 && PyErr_Occurred()) {
            return NULL;
        }
        if (max_commits < 0) {
            PyErr_SetString(PyExc_ValueError, "max_commits must not be negative");
            return NULL;
        }
    }

    git_repository *repo = NULL;
    if (open_repository(path, &repo) < 0) {
        return NULL;
    }
    git_mailmap *mailmap = NULL;
    git_revwalk *walk = NULL;
    PyObject *result = NULL;
    int rc;

    if ((rc = git_mailmap_from_repository(&mailmap, repo)) < 0) {
        raise_git_error(rc, "mailmap");
        goto done;
    }
    if ((rc = git_revwalk_new(&walk, repo)) < 0 || (rc = git_revwalk_sorting(walk, GIT_SORT_TIME)) < 0) {
        raise_git_error(rc, "revwalk");
        goto done;
    }
    result = PyList_New(0);
    if (result == NULL) {
        goto done;
    }
    rc = git_repository_head_unborn(repo);
    if (rc == 1) {
        goto done;
    }
    if (rc == 0) {
        rc = git_revwalk_push_head(walk);
    }
    if (rc < 0) {
        raise_git_error(rc, "HEAD");
        Py_CLEAR(result);
        goto done;
    }

    git_oid oid;
    while (max_commits < 0 || PyList_GET_SIZE(result) < max_commits) {
        git_commit *commit = NULL;
        git_signature *author = NULL;
        const char *failed = NULL;

        Py_BEGIN_ALLOW_THREADS
        rc = git_revwalk_next(&oid, walk);
        if (rc == 0 && (rc = git_commit_lookup(&commit, repo, &oid)) < 0) {
            failed = "commit";
        }
        Py_END_ALLOW_THREADS

        if (rc == GIT_ITEROVER) {
            break;
        }
        if (rc < 0) {
            raise_git_error(rc, failed != NULL ? failed : "revwalk");
            Py_CLEAR(result);
            goto done;
        }
        unsigned int parents = git_commit_parentcount(commit);
        if (parents > 1) {
            /* Merges restate their parents' paths and would double-count. */
            git_commit_free(commit);
            continue;
        }
        if ((rc = git_commit_author_with_mailmap(&author, commit, mailmap)) < 0) {
            git_commit_free(commit);
            raise_git_error(rc, "author");
            Py_CLEAR(result);
            goto done;
        }
        PyObject *paths = changed_paths(repo, commit, parents);
        PyObject *entry = NULL;
        if (paths != NULL) {
            PyObject *name = decode(author->name);
            PyObject *email = decode(author->email);
            if (name != NULL && email != NULL) {
                entry = PyTuple_Pack(3, name, email, paths);
            }
            Py_XDECREF(name);
            Py_XDECREF(email);
            Py_DECREF(paths);
        }
        git_signature_free(author);
        git_commit_free(commit);
        if (entry == NULL || PyList_Append(result, entry) < 0) {
            Py_XDECREF(entry);
            Py_CLEAR(result);
            goto done;
        }
        Py_DECREF(entry);
    }

done:
    git_revwalk_free(walk);
    git_mailmap_free(mailmap);
    git_repository_free(repo);
    return result;
}

static PyMethodDef methods[] = {
    {"version", version, METH_NOARGS, version_doc},
    {"features", features, METH_NOARGS, features_doc},
    {"remote_url", (PyCFunction)(void (*)(void))remote_url, METH_VARARGS | METH_KEYWORDS, remote_url_doc},
    {"index_entry_count", index_entry_count, METH_O, index_entry_count_doc},
    {"commit_paths", (PyCFunction)(void (*)(void))commit_paths, METH_VARARGS | METH_KEYWORDS, commit_paths_doc},
    {NULL, NULL, 0, NULL},
};

static int
exec_module(PyObject *module)
{
    /* Counted: each initialisation after the first only increments. Never shut down. */
    if (git_libgit2_init() < 0) {
        raise_git_error(-1, "git_libgit2_init");
        return -1;
    }
    if (GitError == NULL) {
        GitError = PyErr_NewExceptionWithDoc(
            "_garage_git.GitError", "A libgit2 call failed.", PyExc_RuntimeError, NULL);
        if (GitError == NULL) {
            return -1;
        }
    }
    return PyModule_AddObjectRef(module, "GitError", GitError);
}

static PyModuleDef_Slot slots[] = {
    {Py_mod_exec, exec_module},
#ifdef Py_mod_multiple_interpreters
    {Py_mod_multiple_interpreters, Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED},
#endif
#ifdef Py_GIL_DISABLED
    /* Every call opens its own repository, and libgit2 is built thread-safe. */
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
#endif
    {0, NULL},
};

static struct PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_garage_git",
    .m_doc = "Local, read-only git history through a statically linked libgit2.",
    .m_size = 0,
    .m_methods = methods,
    .m_slots = slots,
};

PyMODINIT_FUNC
PyInit__garage_git(void)
{
    return PyModuleDef_Init(&module_def);
}
