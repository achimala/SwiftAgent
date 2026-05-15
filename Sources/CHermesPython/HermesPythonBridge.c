#include "HermesPythonBridge.h"

#include <Python/Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

static int g_initialized = 0;
static HermesPython_StreamCallback g_stream_callback = NULL;
static void *g_stream_context = NULL;
static HermesPython_ShellCallback g_shell_callback = NULL;
static void *g_shell_context = NULL;

static void set_error(char *buffer, int capacity, const char *message) {
    if (buffer == NULL || capacity <= 0) {
        return;
    }
    if (message == NULL) {
        message = "Unknown Python error";
    }
    snprintf(buffer, (size_t)capacity, "%s", message);
}

static FILE *command_stdout(void) {
    return thread_stdout != NULL ? thread_stdout : stdout;
}

static FILE *command_stderr(void) {
    return thread_stderr != NULL ? thread_stderr : stderr;
}

static void command_write(FILE *stream, const char *text) {
    if (stream == NULL || text == NULL || text[0] == '\0') {
        return;
    }
    fputs(text, stream);
    fflush(stream);
}

static char *read_all(FILE *stream) {
    if (stream == NULL) {
        return strdup("");
    }

    size_t capacity = 4096;
    size_t length = 0;
    char *buffer = (char *)malloc(capacity);
    if (buffer == NULL) {
        return NULL;
    }

    int ch = 0;
    while ((ch = fgetc(stream)) != EOF) {
        if (length + 1 >= capacity) {
            capacity *= 2;
            char *grown = (char *)realloc(buffer, capacity);
            if (grown == NULL) {
                free(buffer);
                return NULL;
            }
            buffer = grown;
        }
        buffer[length++] = (char)ch;
    }
    buffer[length] = '\0';
    return buffer;
}

static int set_python_argv(int argc, char **argv, int start_index, const char *argv0_override) {
    int py_argc = argc - start_index;
    if (py_argc < 1) {
        py_argc = 1;
    }

    PyObject *list = PyList_New(py_argc);
    if (list == NULL) {
        return -1;
    }

    for (int i = 0; i < py_argc; i++) {
        const char *value = NULL;
        if (i == 0 && argv0_override != NULL) {
            value = argv0_override;
        } else if (start_index + i < argc && argv[start_index + i] != NULL) {
            value = argv[start_index + i];
        } else {
            value = "";
        }

        PyObject *item = PyUnicode_FromString(value);
        if (item == NULL) {
            Py_DECREF(list);
            return -1;
        }
        PyList_SET_ITEM(list, i, item);
    }

    int result = PySys_SetObject("argv", list);
    Py_DECREF(list);
    return result;
}

static int run_python_with_capture(int (*runner)(void *context), void *context) {
    PyObject *io_module = PyImport_ImportModule("io");
    if (io_module == NULL) {
        PyErr_Print();
        return 1;
    }

    PyObject *stdout_buffer = PyObject_CallMethod(io_module, "StringIO", NULL);
    PyObject *stderr_buffer = PyObject_CallMethod(io_module, "StringIO", NULL);
    Py_DECREF(io_module);
    if (stdout_buffer == NULL || stderr_buffer == NULL) {
        Py_XDECREF(stdout_buffer);
        Py_XDECREF(stderr_buffer);
        PyErr_Print();
        return 1;
    }

    PyObject *old_stdout = PySys_GetObject("stdout");
    PyObject *old_stderr = PySys_GetObject("stderr");
    Py_XINCREF(old_stdout);
    Py_XINCREF(old_stderr);
    PySys_SetObject("stdout", stdout_buffer);
    PySys_SetObject("stderr", stderr_buffer);

    int status = runner(context);

    PySys_SetObject("stdout", old_stdout ? old_stdout : Py_None);
    PySys_SetObject("stderr", old_stderr ? old_stderr : Py_None);
    Py_XDECREF(old_stdout);
    Py_XDECREF(old_stderr);

    PyObject *stdout_text = PyObject_CallMethod(stdout_buffer, "getvalue", NULL);
    PyObject *stderr_text = PyObject_CallMethod(stderr_buffer, "getvalue", NULL);
    Py_DECREF(stdout_buffer);
    Py_DECREF(stderr_buffer);

    if (stdout_text != NULL) {
        command_write(command_stdout(), PyUnicode_AsUTF8(stdout_text));
        Py_DECREF(stdout_text);
    }
    if (stderr_text != NULL) {
        command_write(command_stderr(), PyUnicode_AsUTF8(stderr_text));
        Py_DECREF(stderr_text);
    }

    return status;
}

struct PythonStringContext {
    const char *code;
    const char *filename;
};

static int handle_system_exit(void) {
    PyObject *type = NULL;
    PyObject *value = NULL;
    PyObject *traceback = NULL;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);

    int status = 0;
    PyObject *code = value ? PyObject_GetAttrString(value, "code") : NULL;
    if (code == NULL || code == Py_None) {
        status = 0;
    } else if (PyLong_Check(code)) {
        status = (int)PyLong_AsLong(code);
        if (PyErr_Occurred()) {
            PyErr_Clear();
            status = 1;
        }
    } else {
        PyObject *text = PyObject_Str(code);
        if (text != NULL) {
            const char *utf8 = PyUnicode_AsUTF8(text);
            if (utf8 != NULL) {
                command_write(command_stderr(), utf8);
                command_write(command_stderr(), "\n");
            }
            Py_DECREF(text);
        }
        status = 1;
    }

    Py_XDECREF(code);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    return status;
}

static int run_python_source(const char *code, const char *filename) {
    PyObject *main_module = PyImport_AddModule("__main__");
    if (main_module == NULL) {
        PyErr_Print();
        return 1;
    }

    PyObject *globals = PyModule_GetDict(main_module);
    if (globals == NULL) {
        PyErr_Print();
        return 1;
    }

    PyObject *name_object = PyUnicode_FromString("__main__");
    if (name_object != NULL) {
        PyDict_SetItemString(globals, "__name__", name_object);
        Py_DECREF(name_object);
    }
    if (filename != NULL && filename[0] != '\0') {
        PyObject *file_object = PyUnicode_FromString(filename);
        if (file_object != NULL) {
            PyDict_SetItemString(globals, "__file__", file_object);
            Py_DECREF(file_object);
        }
    } else {
        PyDict_DelItemString(globals, "__file__");
        PyErr_Clear();
    }

    PyObject *result = PyRun_StringFlags(
        code ? code : "",
        Py_file_input,
        globals,
        globals,
        NULL
    );
    if (result != NULL) {
        Py_DECREF(result);
        return 0;
    }

    if (PyErr_ExceptionMatches(PyExc_SystemExit)) {
        return handle_system_exit();
    }

    PyErr_Print();
    return 1;
}

static int run_python_string_context(void *raw_context) {
    struct PythonStringContext *context = (struct PythonStringContext *)raw_context;
    return run_python_source(context->code, context->filename);
}

struct PythonFileContext {
    const char *path;
};

static int run_python_file_context(void *raw_context) {
    struct PythonFileContext *context = (struct PythonFileContext *)raw_context;
    FILE *file = fopen(context->path, "r");
    if (file == NULL) {
        fprintf(command_stderr(), "python3: can't open file '%s'\n", context->path);
        return 1;
    }
    char *code = read_all(file);
    fclose(file);
    if (code == NULL) {
        fprintf(command_stderr(), "python3: failed to read file '%s'\n", context->path);
        return 1;
    }
    struct PythonStringContext string_context = { code, context->path };
    int status = run_python_string_context(&string_context);
    free(code);
    return status;
}

__attribute__((used, visibility("default")))
int python3_main(int argc, char **argv) {
    if (!Py_IsInitialized()) {
        fprintf(command_stderr(), "python3: embedded Python is not initialized\n");
        return 1;
    }

    if (argc >= 2 && (strcmp(argv[1], "-V") == 0 || strcmp(argv[1], "--version") == 0)) {
        fprintf(command_stdout(), "Python %s\n", Py_GetVersion());
        return 0;
    }

    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        fprintf(command_stdout(), "usage: python3 [-c command] [script.py|-] [args...]\n");
        return 0;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    int status = 1;

    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        if (set_python_argv(argc, argv, 2, "-c") != 0) {
            PyErr_Print();
            status = 1;
        } else {
            struct PythonStringContext context = { argv[2], NULL };
            status = run_python_with_capture(run_python_string_context, &context);
        }
    } else if (argc >= 2 && strcmp(argv[1], "-") == 0) {
        char *code = read_all(thread_stdin);
        if (code == NULL) {
            fprintf(command_stderr(), "python3: failed to read stdin\n");
            status = 1;
        } else if (set_python_argv(argc, argv, 1, "-") != 0) {
            PyErr_Print();
            status = 1;
            free(code);
        } else {
            struct PythonStringContext context = { code, "<stdin>" };
            status = run_python_with_capture(run_python_string_context, &context);
            free(code);
        }
    } else if (argc >= 2) {
        if (set_python_argv(argc, argv, 1, NULL) != 0) {
            PyErr_Print();
            status = 1;
        } else {
            struct PythonFileContext context = { argv[1] };
            status = run_python_with_capture(run_python_file_context, &context);
        }
    } else {
        fprintf(command_stderr(), "python3: interactive mode is not available in HermesAgentKit\n");
        status = 1;
    }

    PyGILState_Release(gil);
    return status;
}

__attribute__((used, visibility("default")))
int python_main(int argc, char **argv) {
    return python3_main(argc, argv);
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

static PyObject *agentkit_run_shell(PyObject *self, PyObject *args) {
    const char *command = NULL;
    const char *cwd = NULL;
    int timeout = 60;

    if (!PyArg_ParseTuple(args, "s|zi", &command, &cwd, &timeout)) {
        return NULL;
    }

    if (g_shell_callback == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "No native shell callback is registered.");
        return NULL;
    }

    int status = -1;
    char *output = NULL;
    Py_BEGIN_ALLOW_THREADS
    output = g_shell_callback(command, cwd, timeout, &status, g_shell_context);
    Py_END_ALLOW_THREADS
    if (output == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Native shell callback failed.");
        return NULL;
    }

    PyObject *result = PyDict_New();
    PyObject *output_object = PyUnicode_FromString(output);
    PyObject *status_object = PyLong_FromLong(status);
    free(output);

    if (result == NULL || output_object == NULL || status_object == NULL) {
        Py_XDECREF(result);
        Py_XDECREF(output_object);
        Py_XDECREF(status_object);
        return NULL;
    }

    PyDict_SetItemString(result, "output", output_object);
    PyDict_SetItemString(result, "exit_code", status_object);
    if (status == 0) {
        Py_INCREF(Py_None);
        PyDict_SetItemString(result, "error", Py_None);
        Py_DECREF(Py_None);
    } else {
        PyObject *error_object = PyUnicode_FromFormat("Command exited with status %d", status);
        if (error_object != NULL) {
            PyDict_SetItemString(result, "error", error_object);
            Py_DECREF(error_object);
        }
    }

    Py_DECREF(output_object);
    Py_DECREF(status_object);
    return result;
}

static PyMethodDef AgentKitMethods[] = {
    {"emit_stream", agentkit_emit_stream, METH_VARARGS, "Emit a Hermes stream event to the native host."},
    {"run_shell", agentkit_run_shell, METH_VARARGS, "Run a shell command through the native host."},
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

void HermesPython_RegisterShellCallback(HermesPython_ShellCallback callback, void *user_context) {
    g_shell_callback = callback;
    g_shell_context = user_context;
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
    int enable_soul,
    int enable_context,
    int enable_memory,
    char *error,
    int error_capacity
) {
    if (!Py_IsInitialized()) {
        set_error(error, error_capacity, "Python is not initialized");
        return NULL;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *args = Py_BuildValue(
        "(sssiii)",
        base_url ? base_url : "",
        api_key ? api_key : "",
        model ? model : "",
        enable_soul ? 1 : 0,
        enable_context ? 1 : 0,
        enable_memory ? 1 : 0
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
