#include "flutter_window.h"
#include "game_process_priority.h"

#include <optional>
#include <cwchar>
#include <flutter/standard_method_codec.h>
#include <tlhelp32.h>
#include <unordered_set>

#include "flutter/generated_plugin_registrant.h"

namespace {
struct GameWindows {
  std::unordered_set<DWORD> processes;
  bool visible = false;
};

BOOL CALLBACK FindGameWindow(HWND window, LPARAM data) {
  auto* search = reinterpret_cast<GameWindows*>(data);
  DWORD owner = 0;
  GetWindowThreadProcessId(window, &owner);
  if (!search->processes.count(owner) || !IsWindowVisible(window)) return TRUE;
  wchar_t name[128] = {};
  GetClassNameW(window, name, 128);
  if (wcscmp(name, L"ConsoleWindowClass") == 0) return TRUE;
  RECT bounds;
  if (GetWindowRect(window, &bounds) && bounds.right - bounds.left >= 64 &&
      bounds.bottom - bounds.top >= 64) {
    search->visible = true;
    return FALSE;
  }
  return TRUE;
}

bool GameWindowVisible(DWORD pid) {
  GameWindows search;
  search.processes.insert(pid);
  // Launch wrappers may create a child JVM; never include unrelated Java clients.
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    bool changed;
    do {
      changed = false;
      PROCESSENTRY32W entry = {};
      entry.dwSize = sizeof(entry);
      if (Process32FirstW(snapshot, &entry)) {
        do {
          if (search.processes.count(entry.th32ParentProcessID) &&
              search.processes.insert(entry.th32ProcessID).second) changed = true;
        } while (Process32NextW(snapshot, &entry));
      }
    } while (changed);
    CloseHandle(snapshot);
  }
  EnumWindows(FindGameWindow, reinterpret_cast<LPARAM>(&search));
  return search.visible;
}
}  // namespace

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
  game_process_priorities_ = std::make_unique<GameProcessPriorities>(
      flutter_controller_->engine()->messenger());
  game_window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "fyl/game_window",
      &flutter::StandardMethodCodec::GetInstance());
  game_window_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "isVisible") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int64_t pid = 0;
    if (args) {
      auto value = args->find(flutter::EncodableValue("pid"));
      if (value != args->end()) {
        if (const auto* int32_value = std::get_if<int32_t>(&value->second)) pid = *int32_value;
        else if (const auto* int64_value = std::get_if<int64_t>(&value->second)) pid = *int64_value;
      }
    }
    if (pid <= 0 || pid > MAXDWORD) { result->Error("invalid_pid", "Invalid game PID"); return; }
    result->Success(flutter::EncodableValue(GameWindowVisible(static_cast<DWORD>(pid))));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  game_process_priorities_ = nullptr;
  game_window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
