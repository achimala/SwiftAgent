#include "HermesPythonBridge.h"

#include <Python/Python.h>
#include <stdlib.h>
#include <string.h>

static int g_initialized = 0;
static HermesPython_StreamCallback g_stream_callback = NULL;
static void *g_stream_context = NULL;

static void set_error(char *buffer, int capacity, const char *message) {
    if (buffer == NULL || capacity <= 0) {
        return;
    }
    if (message == NULL) {
        message = "Unknown Python error";
    }
    snprintf(buffer, (size_t)capacity, "%s", message);
}

static void set_python_error(char *buffer, int capacity) {
    if (!PyErr_Occurred()) {
        set_error(buffer, capacity, "Python operation failed without an active exception");
        return;
    }

    PyObject *type = NULL;
    PyObject *value = NULL;
    PyObject *traceback = NULL;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);

    PyObject *traceback_module = PyImport_ImportModule("traceback");
    if (traceback_module != NULL) {
        PyObject *format_exception = PyObject_GetAttrString(traceback_module, "format_exception");
        if (format_exception != NULL) {
            PyObject *formatted = PyObject_CallFunctionObjArgs(
                format_exception,
                type ? type : Py_None,
                value ? value : Py_None,
                traceback ? traceback : Py_None,
                NULL
            );
            if (formatted != NULL) {
                PyObject *separator = PyUnicode_FromString("");
                PyObject *joined = separator ? PyUnicode_Join(separator, formatted) : NULL;
                if (joined != NULL) {
                    const char *utf8 = PyUnicode_AsUTF8(joined);
                    set_error(buffer, capacity, utf8);
                    Py_DECREF(joined);
                    Py_DECREF(separator);
                    Py_DECREF(formatted);
                    Py_DECREF(format_exception);
                    Py_DECREF(traceback_module);
                    Py_XDECREF(type);
                    Py_XDECREF(value);
                    Py_XDECREF(traceback);
                    return;
                }
                Py_XDECREF(separator);
                Py_DECREF(formatted);
            }
            Py_DECREF(format_exception);
        }
        Py_DECREF(traceback_module);
    }

    PyObject *text = value ? PyObject_Str(value) : NULL;
    const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
    set_error(buffer, capacity, utf8);
    Py_XDECREF(text);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
}

static int append_path(PyConfig *config, const char *path, char *error, int error_capacity) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }

    wchar_t *wide_path = Py_DecodeLocale(path, NULL);
    if (wide_path == NULL) {
        set_error(error, error_capacity, "Could not decode Python path");
        return -1;
    }

    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide_path);
    PyMem_RawFree(wide_path);
    if (PyStatus_Exception(status)) {
        set_error(error, error_capacity, status.err_msg);
        return -1;
    }
    return 0;
}

static PyObject *agentkit_emit_stream(PyObject *self, PyObject *args) {
    const char *event = NULL;
    const char *payload = NULL;

    if (!PyArg_ParseTuple(args, "zz", &event, &payload)) {
        return NULL;
    }

    if (g_stream_callback != NULL) {
        g_stream_callback(event ? event : "", payload ? payload : "", g_stream_context);
    }

    Py_RETURN_NONE;
}

static PyMethodDef AgentKitMethods[] = {
    {"emit_stream", agentkit_emit_stream, METH_VARARGS, "Emit a Hermes stream event to the native host."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef AgentKitModule = {
    PyModuleDef_HEAD_INIT,
    "_hermes_agentkit",
    "Native callbacks for HermesAgentKit.",
    -1,
    AgentKitMethods
};

static int install_agentkit_module(char *error, int error_capacity) {
    PyObject *module = PyModule_Create(&AgentKitModule);
    if (module == NULL) {
        set_python_error(error, error_capacity);
        return -1;
    }

    PyObject *modules = PyImport_GetModuleDict();
    if (PyDict_SetItemString(modules, "_hermes_agentkit", module) != 0) {
        Py_DECREF(module);
        set_python_error(error, error_capacity);
        return -1;
    }

    Py_DECREF(module);
    return 0;
}

static char *copy_python_string(PyObject *result, char *error, int error_capacity) {
    PyObject *text = PyObject_Str(result);
    if (text == NULL) {
        set_python_error(error, error_capacity);
        return NULL;
    }

    const char *utf8 = PyUnicode_AsUTF8(text);
    if (utf8 == NULL) {
        Py_DECREF(text);
        set_python_error(error, error_capacity);
        return NULL;
    }

    char *copy = strdup(utf8);
    Py_DECREF(text);
    if (copy == NULL) {
        set_error(error, error_capacity, "Could not allocate Python result");
        return NULL;
    }
    return copy;
}

static char *call_bootstrap_function(
    const char *function_name,
    PyObject *args,
    char *error,
    int error_capacity
) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        Py_XDECREF(args);
        return NULL;
    }

    PyObject *module = PyImport_ImportModule("agentkit_bootstrap");
    if (module == NULL) {
        Py_XDECREF(args);
        set_python_error(error, error_capacity);
        return NULL;
    }

    PyObject *function = PyObject_GetAttrString(module, function_name);
    Py_DECREF(module);
    if (function == NULL) {
        Py_XDECREF(args);
        set_python_error(error, error_capacity);
        return NULL;
    }

    PyObject *result = PyObject_CallObject(function, args);
    Py_DECREF(function);
    Py_XDECREF(args);
    if (result == NULL) {
        set_python_error(error, error_capacity);
        return NULL;
    }

    char *copy = copy_python_string(result, error, error_capacity);
    Py_DECREF(result);
    return copy;
}

int HermesPython_Initialize(const char *python_home, const char *python_paths, char *error, int error_capacity) {
    if (g_initialized || Py_IsInitialized()) {
        g_initialized = 1;
        return 0;
    }

    if (python_home == NULL || python_home[0] == '\0') {
        set_error(error, error_capacity, "python_home is required");
        return -1;
    }

    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.use_environment = 0;
    config.user_site_directory = 0;
    config.site_import = 1;
    config.module_search_paths_set = 1;

    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) {
        set_error(error, error_capacity, status.err_msg);
        PyConfig_Clear(&config);
        return -1;
    }

    if (python_paths != NULL && python_paths[0] != '\0') {
        char *paths_copy = strdup(python_paths);
        if (paths_copy == NULL) {
            set_error(error, error_capacity, "Could not allocate Python path buffer");
            PyConfig_Clear(&config);
            return -1;
        }

        char *saveptr = NULL;
        char *part = strtok_r(paths_copy, ":", &saveptr);
        while (part != NULL) {
            if (append_path(&config, part, error, error_capacity) != 0) {
                free(paths_copy);
                PyConfig_Clear(&config);
                return -1;
            }
            part = strtok_r(NULL, ":", &saveptr);
        }
        free(paths_copy);
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        set_error(error, error_capacity, status.err_msg);
        return -1;
    }

    if (install_agentkit_module(error, error_capacity) != 0) {
        return -1;
    }

    g_initialized = 1;
    PyEval_SaveThread();
    return 0;
}

int HermesPython_IsInitialized(void) {
    return g_initialized || Py_IsInitialized();
}

char *HermesPython_Evaluate(const char *code, char *error, int error_capacity) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        return NULL;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *main_module = PyImport_AddModule("__main__");
    PyObject *globals = PyModule_GetDict(main_module);
    PyObject *result = PyRun_String(code, Py_eval_input, globals, globals);
    if (result == NULL) {
        set_python_error(error, error_capacity);
        PyGILState_Release(gil);
        return NULL;
    }

    char *copy = copy_python_string(result, error, error_capacity);
    Py_DECREF(result);
    PyGILState_Release(gil);
    return copy;
}

char *HermesPython_RunScript(const char *code, char *error, int error_capacity) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        return NULL;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *main_module = PyImport_AddModule("__main__");
    PyObject *globals = PyModule_GetDict(main_module);
    PyObject *result = PyRun_String(code, Py_file_input, globals, globals);
    if (result == NULL) {
        set_python_error(error, error_capacity);
        PyGILState_Release(gil);
        return NULL;
    }
    Py_DECREF(result);
    char *copy = strdup("ok");
    PyGILState_Release(gil);
    return copy;
}

char *HermesPython_ConfigureHermes(
    const char *base_url,
    const char *api_key,
    const char *model,
    char *error,
    int error_capacity
) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        return NULL;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *args = Py_BuildValue(
        "(sss)",
        base_url ? base_url : "",
        api_key ? api_key : "",
        model ? model : ""
    );
    if (args == NULL) {
        set_python_error(error, error_capacity);
        PyGILState_Release(gil);
        return NULL;
    }
    char *result = call_bootstrap_function("hermes_configure", args, error, error_capacity);
    PyGILState_Release(gil);
    return result;
}

char *HermesPython_Chat(
    const char *message,
    HermesPython_StreamCallback callback,
    void *user_context,
    char *error,
    int error_capacity
) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        return NULL;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *args = Py_BuildValue("(s)", message ? message : "");
    if (args == NULL) {
        set_python_error(error, error_capacity);
        PyGILState_Release(gil);
        return NULL;
    }

    g_stream_callback = callback;
    g_stream_context = user_context;
    char *result = call_bootstrap_function("hermes_chat", args, error, error_capacity);
    g_stream_callback = NULL;
    g_stream_context = NULL;
    PyGILState_Release(gil);
    return result;
}

void HermesPython_FreeCString(char *value) {
    free(value);
}
