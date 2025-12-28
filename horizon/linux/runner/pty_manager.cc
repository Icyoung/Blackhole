#include "pty_manager.h"

#include <pty.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <uuid/uuid.h>
#include <cstring>
#include <cstdlib>

static PtyManager* g_pty_manager = nullptr;
static FlMethodChannel* g_method_channel = nullptr;
static FlEventChannel* g_event_channel = nullptr;
static FlEventSink* g_event_sink = nullptr;

PtyManager::PtyManager() {}

PtyManager::~PtyManager() {
  for (auto& pair : sessions_) {
    pair.second->running = false;
    if (pair.second->read_thread.joinable()) {
      pair.second->read_thread.join();
    }
    close(pair.second->master_fd);
    ::kill(pair.second->child_pid, SIGTERM);
  }
}

void PtyManager::set_output_callback(OutputCallback callback) {
  output_callback_ = callback;
}

std::string PtyManager::generate_uuid() {
  uuid_t uuid;
  uuid_generate(uuid);
  char uuid_str[37];
  uuid_unparse_upper(uuid, uuid_str);
  return std::string(uuid_str);
}

std::string PtyManager::start_shell(int rows, int cols, const char* shell_path) {
  int master_fd;
  struct winsize ws = {
    .ws_row = static_cast<unsigned short>(rows),
    .ws_col = static_cast<unsigned short>(cols),
    .ws_xpixel = 0,
    .ws_ypixel = 0
  };

  pid_t pid = forkpty(&master_fd, nullptr, nullptr, &ws);
  if (pid < 0) {
    return "";
  }

  if (pid == 0) {
    // Child process - determine shell to use
    const char* shell = shell_path;
    if (!shell || strlen(shell) == 0) {
      // Try $SHELL first, then fall back to /bin/bash, /bin/sh
      shell = getenv("SHELL");
      if (!shell || access(shell, X_OK) != 0) {
        if (access("/bin/bash", X_OK) == 0) {
          shell = "/bin/bash";
        } else {
          shell = "/bin/sh";
        }
      }
    }

    const char* home = getenv("HOME");
    if (home) {
      chdir(home);
    }

    // Set up environment
    setenv("TERM", "xterm-256color", 1);

    execlp(shell, shell, "-i", "-l", nullptr);
    _exit(1);
  }

  // Parent process
  int flags = fcntl(master_fd, F_GETFL);
  fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

  std::string session_id = generate_uuid();
  auto session = std::make_unique<PtySession>();
  session->id = session_id;
  session->master_fd = master_fd;
  session->child_pid = pid;
  session->running = true;

  PtySession* session_ptr = session.get();
  session->read_thread = std::thread(&PtyManager::read_loop, this, session_ptr);

  sessions_[session_id] = std::move(session);
  return session_id;
}

void PtyManager::read_loop(PtySession* session) {
  uint8_t buffer[4096];
  while (session->running) {
    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(session->master_fd, &read_fds);

    struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};  // 100ms
    int ret = select(session->master_fd + 1, &read_fds, nullptr, nullptr, &timeout);

    if (ret > 0 && FD_ISSET(session->master_fd, &read_fds)) {
      ssize_t n = read(session->master_fd, buffer, sizeof(buffer));
      if (n > 0) {
        if (output_callback_) {
          output_callback_(session->id, buffer, static_cast<size_t>(n));
        }
      } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
        break;
      }
    }
  }
}

void PtyManager::write_stdin(const std::string& session_id, const uint8_t* data, size_t len) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) {
    return;
  }
  write(it->second->master_fd, data, len);
}

void PtyManager::resize(const std::string& session_id, int rows, int cols) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) {
    return;
  }
  struct winsize ws = {
    .ws_row = static_cast<unsigned short>(rows),
    .ws_col = static_cast<unsigned short>(cols),
    .ws_xpixel = 0,
    .ws_ypixel = 0
  };
  ioctl(it->second->master_fd, TIOCSWINSZ, &ws);
}

void PtyManager::kill_session(const std::string& session_id) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) {
    return;
  }
  it->second->running = false;
  if (it->second->read_thread.joinable()) {
    it->second->read_thread.join();
  }
  close(it->second->master_fd);
  ::kill(it->second->child_pid, SIGTERM);
  sessions_.erase(it);
}

// Flutter method channel handler
static void method_call_handler(FlMethodChannel* channel,
                                FlMethodCall* method_call,
                                gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "startShell") == 0) {
    int rows = 24, cols = 80;
    const char* shell_path = nullptr;

    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* rows_val = fl_value_lookup_string(args, "rows");
      FlValue* cols_val = fl_value_lookup_string(args, "cols");
      FlValue* shell_val = fl_value_lookup_string(args, "shellPath");

      if (rows_val && fl_value_get_type(rows_val) == FL_VALUE_TYPE_INT) {
        rows = fl_value_get_int(rows_val);
      }
      if (cols_val && fl_value_get_type(cols_val) == FL_VALUE_TYPE_INT) {
        cols = fl_value_get_int(cols_val);
      }
      if (shell_val && fl_value_get_type(shell_val) == FL_VALUE_TYPE_STRING) {
        shell_path = fl_value_get_string(shell_val);
      }
    }

    std::string session_id = g_pty_manager->start_shell(rows, cols, shell_path);
    if (session_id.empty()) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "PTY_START", "Failed to start shell", nullptr));
    } else {
      g_autoptr(FlValue) result = fl_value_new_string(session_id.c_str());
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "writeStdin") == 0) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* session_val = fl_value_lookup_string(args, "sessionId");
      FlValue* data_val = fl_value_lookup_string(args, "data");

      if (session_val && data_val) {
        const char* session_id = fl_value_get_string(session_val);
        size_t len;
        const uint8_t* data = fl_value_get_uint8_list(data_val, &len);
        g_pty_manager->write_stdin(session_id, data, len);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "resize") == 0) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* session_val = fl_value_lookup_string(args, "sessionId");
      FlValue* rows_val = fl_value_lookup_string(args, "rows");
      FlValue* cols_val = fl_value_lookup_string(args, "cols");

      if (session_val && rows_val && cols_val) {
        const char* session_id = fl_value_get_string(session_val);
        int rows = fl_value_get_int(rows_val);
        int cols = fl_value_get_int(cols_val);
        g_pty_manager->resize(session_id, rows, cols);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "kill") == 0) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* session_val = fl_value_lookup_string(args, "sessionId");
      if (session_val) {
        const char* session_id = fl_value_get_string(session_val);
        g_pty_manager->kill_session(session_id);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// Event channel handlers
static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                               FlValue* args,
                                               gpointer user_data) {
  g_event_sink = fl_event_channel_get_event_sink(channel);
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                               FlValue* args,
                                               gpointer user_data) {
  g_event_sink = nullptr;
  return nullptr;
}

static void send_output_to_flutter(const std::string& session_id,
                                   const uint8_t* data,
                                   size_t len) {
  if (!g_event_sink) {
    return;
  }

  // Must be called from the main thread
  g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer user_data) -> gboolean {
    auto* params = static_cast<std::tuple<std::string, std::vector<uint8_t>>*>(user_data);

    if (g_event_sink) {
      g_autoptr(FlValue) event = fl_value_new_map();
      fl_value_set_string_take(event, "sessionId",
                               fl_value_new_string(std::get<0>(*params).c_str()));
      fl_value_set_string_take(event, "data",
                               fl_value_new_uint8_list(std::get<1>(*params).data(),
                                                       std::get<1>(*params).size()));
      fl_event_sink_send(g_event_sink, event, nullptr);
    }

    delete params;
    return G_SOURCE_REMOVE;
  }, new std::tuple<std::string, std::vector<uint8_t>>(
      session_id, std::vector<uint8_t>(data, data + len)), nullptr);
}

void pty_manager_register_with_registrar(FlPluginRegistrar* registrar) {
  g_pty_manager = new PtyManager();
  g_pty_manager->set_output_callback(send_output_to_flutter);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  // Method channel
  g_method_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.blackhole/pty",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_method_channel, method_call_handler,
                                            nullptr, nullptr);

  // Event channel
  g_event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.blackhole/pty/output",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_event_channel, event_listen_cb,
                                       event_cancel_cb, nullptr, nullptr);
}
