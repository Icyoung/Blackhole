#ifndef PTY_MANAGER_H_
#define PTY_MANAGER_H_

#include <flutter_linux/flutter_linux.h>
#include <map>
#include <string>
#include <functional>
#include <thread>
#include <atomic>

struct PtySession {
  std::string id;
  int master_fd;
  pid_t child_pid;
  std::thread read_thread;
  std::atomic<bool> running;
};

class PtyManager {
 public:
  using OutputCallback = std::function<void(const std::string&, const uint8_t*, size_t)>;

  PtyManager();
  ~PtyManager();

  void set_output_callback(OutputCallback callback);

  std::string start_shell(int rows, int cols, const char* shell_path);
  void write_stdin(const std::string& session_id, const uint8_t* data, size_t len);
  void resize(const std::string& session_id, int rows, int cols);
  void kill_session(const std::string& session_id);

 private:
  std::map<std::string, std::unique_ptr<PtySession>> sessions_;
  OutputCallback output_callback_;

  void read_loop(PtySession* session);
  std::string generate_uuid();
};

// Flutter plugin integration
void pty_manager_register_with_registrar(FlPluginRegistrar* registrar);

#endif  // PTY_MANAGER_H_
