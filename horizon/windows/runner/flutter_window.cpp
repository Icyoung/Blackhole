#include "flutter_window.h"

#include <cstdlib>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  EnsureTrayIcon();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      if (!allow_close_) {
        if (tray_available_) {
          HideToTray();
          return 0;
        }
      }
      break;
    case kTrayCallbackMessage: {
      switch (lparam) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          ShowFromTray();
          return 0;
        case WM_RBUTTONUP:
          ShowTrayMenu();
          return 0;
        default:
          break;
      }
      break;
    }
    case WM_COMMAND: {
      const UINT cmd = LOWORD(wparam);
      if (cmd == kTrayMenuShow) {
        ShowFromTray();
        return 0;
      }
      if (cmd == kTrayMenuQuit) {
        RequestQuit();
        return 0;
      }
      break;
    }
    case WM_DESTROY:
      RemoveTrayIcon();
      break;
    default:
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::EnsureTrayIcon() {
  if (tray_initialized_) {
    return;
  }
  tray_menu_ = CreatePopupMenu();
  AppendMenuW(tray_menu_, MF_STRING, kTrayMenuShow, L"Show Horizon");
  AppendMenuW(tray_menu_, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(tray_menu_, MF_STRING, kTrayMenuQuit, L"Quit");

  tray_icon_data_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_data_.hWnd = GetHandle();
  tray_icon_data_.uID = 1;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_data_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_data_.szTip, L"Horizon");

  tray_available_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_data_) != FALSE;
  if (!tray_available_) {
    if (tray_menu_ != nullptr) {
      DestroyMenu(tray_menu_);
      tray_menu_ = nullptr;
    }
    return;
  }
  tray_icon_data_.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_data_);
  tray_initialized_ = true;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_initialized_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
    tray_initialized_ = false;
  }
  tray_available_ = false;
  if (tray_menu_ != nullptr) {
    DestroyMenu(tray_menu_);
    tray_menu_ = nullptr;
  }
}

void FlutterWindow::HideToTray() {
  EnsureTrayIcon();
  if (!tray_available_) {
    return;
  }
  ShowWindow(GetHandle(), SW_HIDE);
}

void FlutterWindow::ShowFromTray() {
  Show();
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  if (!tray_initialized_ || tray_menu_ == nullptr) {
    return;
  }
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(tray_menu_, TPM_RIGHTBUTTON, pt.x, pt.y, 0, GetHandle(),
                 nullptr);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
}

void FlutterWindow::RequestQuit() {
  StopDaemonIfRunning();
  allow_close_ = true;
  Destroy();
}

void FlutterWindow::StopDaemonIfRunning() {
  wchar_t profile[MAX_PATH];
  DWORD len = GetEnvironmentVariableW(L"USERPROFILE", profile, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return;
  }
  std::wstring pid_path =
      std::wstring(profile) + L"\\.blackhole\\horizon\\daemon.pid";

  HANDLE file = CreateFileW(pid_path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  char buf[64] = {};
  DWORD bytes_read = 0;
  BOOL ok = ReadFile(file, buf, sizeof(buf) - 1, &bytes_read, nullptr);
  CloseHandle(file);
  if (!ok || bytes_read == 0) {
    return;
  }

  std::string pid_text(buf, bytes_read);
  size_t start = pid_text.find_first_not_of(" \t\r\n");
  if (start == std::string::npos) {
    return;
  }
  size_t end = pid_text.find_last_not_of(" \t\r\n");
  pid_text = pid_text.substr(start, end - start + 1);

  unsigned long pid_ul = std::strtoul(pid_text.c_str(), nullptr, 10);
  if (pid_ul == 0) {
    return;
  }
  DWORD pid = static_cast<DWORD>(pid_ul);

  HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
  if (proc != nullptr) {
    TerminateProcess(proc, 0);
    CloseHandle(proc);
  }

  DeleteFileW(pid_path.c_str());
}
