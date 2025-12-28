#include "pty_manager.h"

#include <sstream>
#include <vector>
#include <deque>
#include <mutex>
#include <rpc.h>

#pragma comment(lib, "rpcrt4.lib")

static std::unique_ptr<PtyManager> g_pty_manager;
static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_method_channel;
static std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> g_event_channel;
static std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> g_event_sink;

// Thread synchronization for UI thread callbacks
#define WM_PTY_OUTPUT (WM_USER + 1)
static HWND g_message_window = NULL;
static std::mutex g_output_mutex;
static std::deque<std::pair<std::string, std::vector<uint8_t>>> g_output_queue;

static LRESULT CALLBACK PtyMessageWindowProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_PTY_OUTPUT) {
    std::lock_guard<std::mutex> lock(g_output_mutex);
    while (!g_output_queue.empty()) {
      auto event_data = std::move(g_output_queue.front());
      g_output_queue.pop_front();

      if (g_event_sink) {
        flutter::EncodableMap event;
        event[flutter::EncodableValue("sessionId")] = flutter::EncodableValue(event_data.first);
        event[flutter::EncodableValue("data")] = flutter::EncodableValue(event_data.second);
        g_event_sink->Success(flutter::EncodableValue(event));
      }
    }
    return 0;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

PtyManager::PtyManager() {}

PtyManager::~PtyManager() {
  for (auto& pair : sessions_) {
    pair.second->running = false;
    if (pair.second->read_thread.joinable()) {
      pair.second->read_thread.join();
    }
    ClosePseudoConsole(pair.second->hpc);
    CloseHandle(pair.second->input_pipe_read);
    CloseHandle(pair.second->input_pipe_write);
    CloseHandle(pair.second->output_pipe_read);
    CloseHandle(pair.second->output_pipe_write);
    TerminateProcess(pair.second->pi.hProcess, 0);
    CloseHandle(pair.second->pi.hProcess);
    CloseHandle(pair.second->pi.hThread);
  }
}

void PtyManager::set_output_callback(OutputCallback callback) {
  output_callback_ = callback;
}

std::string PtyManager::generate_uuid() {
  UUID uuid;
  UuidCreate(&uuid);
  RPC_CSTR uuid_str;
  UuidToStringA(&uuid, &uuid_str);
  std::string result(reinterpret_cast<char*>(uuid_str));
  RpcStringFreeA(&uuid_str);
  return result;
}

std::string PtyManager::start_shell(int rows, int cols, const wchar_t* shell_path) {
  HRESULT hr;
  HANDLE input_pipe_read = NULL, input_pipe_write = NULL;
  HANDLE output_pipe_read = NULL, output_pipe_write = NULL;
  HPCON hpc = NULL;

  // Create pipes for input/output
  SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), NULL, TRUE};
  if (!CreatePipe(&input_pipe_read, &input_pipe_write, &sa, 0) ||
      !CreatePipe(&output_pipe_read, &output_pipe_write, &sa, 0)) {
    return "";
  }

  // Create pseudo console
  COORD size = {static_cast<SHORT>(cols), static_cast<SHORT>(rows)};
  hr = CreatePseudoConsole(size, input_pipe_read, output_pipe_write, 0, &hpc);
  if (FAILED(hr)) {
    CloseHandle(input_pipe_read);
    CloseHandle(input_pipe_write);
    CloseHandle(output_pipe_read);
    CloseHandle(output_pipe_write);
    return "";
  }

  // Prepare startup info with pseudo console
  STARTUPINFOEXW si = {};
  si.StartupInfo.cb = sizeof(STARTUPINFOEXW);

  size_t attr_list_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_list_size);
  si.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
      HeapAlloc(GetProcessHeap(), 0, attr_list_size));

  if (!si.lpAttributeList ||
      !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_list_size) ||
      !UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                 PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc,
                                 sizeof(HPCON), NULL, NULL)) {
    ClosePseudoConsole(hpc);
    CloseHandle(input_pipe_read);
    CloseHandle(input_pipe_write);
    CloseHandle(output_pipe_read);
    CloseHandle(output_pipe_write);
    if (si.lpAttributeList) {
      HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
    }
    return "";
  }

  // Determine shell to use
  std::wstring shell;
  if (shell_path && wcslen(shell_path) > 0) {
    shell = shell_path;
  } else {
    // Try PowerShell Core, then Windows PowerShell, then CMD
    wchar_t pwsh_path[MAX_PATH];
    wchar_t sys_dir[MAX_PATH];
    GetSystemDirectoryW(sys_dir, MAX_PATH);

    if (SearchPathW(NULL, L"pwsh.exe", NULL, MAX_PATH, pwsh_path, NULL)) {
      shell = pwsh_path;
    } else {
      std::wstring powershell_path = std::wstring(sys_dir) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
      if (GetFileAttributesW(powershell_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
        shell = powershell_path;
      } else {
        // Fallback to cmd.exe
        shell = std::wstring(sys_dir) + L"\\cmd.exe";
      }
    }
  }

  // Create process
  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> cmd_line(shell.begin(), shell.end());
  cmd_line.push_back(L'\0');

  if (!CreateProcessW(NULL, cmd_line.data(), NULL, NULL, FALSE,
                      EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
                      &si.StartupInfo, &pi)) {
    DeleteProcThreadAttributeList(si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
    ClosePseudoConsole(hpc);
    CloseHandle(input_pipe_read);
    CloseHandle(input_pipe_write);
    CloseHandle(output_pipe_read);
    CloseHandle(output_pipe_write);
    return "";
  }

  DeleteProcThreadAttributeList(si.lpAttributeList);
  HeapFree(GetProcessHeap(), 0, si.lpAttributeList);

  // Close the handles we don't need in parent
  CloseHandle(input_pipe_read);
  CloseHandle(output_pipe_write);

  std::string session_id = generate_uuid();
  auto session = std::make_unique<PtySession>();
  session->id = session_id;
  session->hpc = hpc;
  session->input_pipe_read = NULL;
  session->input_pipe_write = input_pipe_write;
  session->output_pipe_read = output_pipe_read;
  session->output_pipe_write = NULL;
  session->pi = pi;
  session->running = true;

  PtySession* session_ptr = session.get();
  session->read_thread = std::thread(&PtyManager::read_loop, this, session_ptr);

  sessions_[session_id] = std::move(session);
  return session_id;
}

void PtyManager::read_loop(PtySession* session) {
  uint8_t buffer[4096];
  DWORD bytes_read;

  while (session->running) {
    DWORD available = 0;
    if (PeekNamedPipe(session->output_pipe_read, NULL, 0, NULL, &available, NULL) &&
        available > 0) {
      if (ReadFile(session->output_pipe_read, buffer, sizeof(buffer),
                   &bytes_read, NULL) && bytes_read > 0) {
        if (output_callback_) {
          output_callback_(session->id, buffer, bytes_read);
        }
      }
    } else {
      Sleep(10);
    }

    // Check if process is still running
    DWORD exit_code;
    if (GetExitCodeProcess(session->pi.hProcess, &exit_code) &&
        exit_code != STILL_ACTIVE) {
      break;
    }
  }
}

void PtyManager::write_stdin(const std::string& session_id, const uint8_t* data, size_t len) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) {
    return;
  }
  DWORD written;
  WriteFile(it->second->input_pipe_write, data, static_cast<DWORD>(len), &written, NULL);
}

void PtyManager::resize(const std::string& session_id, int rows, int cols) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) {
    return;
  }
  COORD size = {static_cast<SHORT>(cols), static_cast<SHORT>(rows)};
  ResizePseudoConsole(it->second->hpc, size);
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
  ClosePseudoConsole(it->second->hpc);
  CloseHandle(it->second->input_pipe_write);
  CloseHandle(it->second->output_pipe_read);
  TerminateProcess(it->second->pi.hProcess, 0);
  CloseHandle(it->second->pi.hProcess);
  CloseHandle(it->second->pi.hThread);
  sessions_.erase(it);
}

// Flutter method handler
static void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = method_call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "startShell") {
    int rows = 24, cols = 80;
    const wchar_t* shell_path = nullptr;
    std::wstring shell_str;

    if (args) {
      auto rows_it = args->find(flutter::EncodableValue("rows"));
      auto cols_it = args->find(flutter::EncodableValue("cols"));
      auto shell_it = args->find(flutter::EncodableValue("shellPath"));

      if (rows_it != args->end() && std::holds_alternative<int>(rows_it->second)) {
        rows = std::get<int>(rows_it->second);
      }
      if (cols_it != args->end() && std::holds_alternative<int>(cols_it->second)) {
        cols = std::get<int>(cols_it->second);
      }
      if (shell_it != args->end() && std::holds_alternative<std::string>(shell_it->second)) {
        std::string path = std::get<std::string>(shell_it->second);
        shell_str = std::wstring(path.begin(), path.end());
        shell_path = shell_str.c_str();
      }
    }

    std::string session_id = g_pty_manager->start_shell(rows, cols, shell_path);
    if (session_id.empty()) {
      result->Error("PTY_START", "Failed to start shell");
    } else {
      result->Success(flutter::EncodableValue(session_id));
    }
  } else if (method == "writeStdin") {
    if (args) {
      auto session_it = args->find(flutter::EncodableValue("sessionId"));
      auto data_it = args->find(flutter::EncodableValue("data"));

      if (session_it != args->end() && data_it != args->end()) {
        std::string session_id = std::get<std::string>(session_it->second);
        auto& data = std::get<std::vector<uint8_t>>(data_it->second);
        g_pty_manager->write_stdin(session_id, data.data(), data.size());
      }
    }
    result->Success();
  } else if (method == "resize") {
    if (args) {
      auto session_it = args->find(flutter::EncodableValue("sessionId"));
      auto rows_it = args->find(flutter::EncodableValue("rows"));
      auto cols_it = args->find(flutter::EncodableValue("cols"));

      if (session_it != args->end() && rows_it != args->end() && cols_it != args->end()) {
        std::string session_id = std::get<std::string>(session_it->second);
        int rows = std::get<int>(rows_it->second);
        int cols = std::get<int>(cols_it->second);
        g_pty_manager->resize(session_id, rows, cols);
      }
    }
    result->Success();
  } else if (method == "kill") {
    if (args) {
      auto session_it = args->find(flutter::EncodableValue("sessionId"));
      if (session_it != args->end()) {
        std::string session_id = std::get<std::string>(session_it->second);
        g_pty_manager->kill_session(session_id);
      }
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

// Event stream handler
class PtyEventStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(const flutter::EncodableValue* arguments,
                   std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    g_event_sink = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    g_event_sink.reset();
    return nullptr;
  }
};

static void SendOutputToFlutter(const std::string& session_id,
                                const uint8_t* data, size_t len) {
  // Post to queue and notify UI thread (thread-safe)
  {
    std::lock_guard<std::mutex> lock(g_output_mutex);
    g_output_queue.emplace_back(session_id, std::vector<uint8_t>(data, data + len));
  }
  if (g_message_window) {
    PostMessage(g_message_window, WM_PTY_OUTPUT, 0, 0);
  }
}

void PtyManagerRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  // Create message-only window for thread synchronization
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(WNDCLASSEXW);
  wc.lpfnWndProc = PtyMessageWindowProc;
  wc.hInstance = GetModuleHandle(NULL);
  wc.lpszClassName = L"PtyManagerMessageWindow";
  RegisterClassExW(&wc);

  g_message_window = CreateWindowExW(
      0, L"PtyManagerMessageWindow", L"", 0,
      0, 0, 0, 0, HWND_MESSAGE, NULL,
      GetModuleHandle(NULL), NULL);

  g_pty_manager = std::make_unique<PtyManager>();
  g_pty_manager->set_output_callback(SendOutputToFlutter);

  auto method_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.blackhole/pty",
      &flutter::StandardMethodCodec::GetInstance());
  method_channel->SetMethodCallHandler(HandleMethodCall);
  g_method_channel = std::move(method_channel);

  auto event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.blackhole/pty/output",
      &flutter::StandardMethodCodec::GetInstance());
  event_channel->SetStreamHandler(std::make_unique<PtyEventStreamHandler>());
  g_event_channel = std::move(event_channel);
}
