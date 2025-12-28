#ifndef PTY_MANAGER_H_
#define PTY_MANAGER_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <string>
#include <memory>
#include <thread>
#include <atomic>
#include <functional>

struct PtySession {
  std::string id;
  HPCON hpc;                    // Pseudo console handle
  HANDLE input_pipe_read;
  HANDLE input_pipe_write;
  HANDLE output_pipe_read;
  HANDLE output_pipe_write;
  PROCESS_INFORMATION pi;
  std::thread read_thread;
  std::atomic<bool> running;
};

class PtyManager {
 public:
  using OutputCallback = std::function<void(const std::string&, const uint8_t*, size_t)>;

  PtyManager();
  ~PtyManager();

  void set_output_callback(OutputCallback callback);

  std::string start_shell(int rows, int cols, const wchar_t* shell_path);
  void write_stdin(const std::string& session_id, const uint8_t* data, size_t len);
  void resize(const std::string& session_id, int rows, int cols);
  void kill_session(const std::string& session_id);

 private:
  std::map<std::string, std::unique_ptr<PtySession>> sessions_;
  OutputCallback output_callback_;

  void read_loop(PtySession* session);
  std::string generate_uuid();
};

// Flutter plugin registration
void PtyManagerRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

#endif  // PTY_MANAGER_H_
