#include "game_process_priority.h"

#include <windows.h>
#include <tlhelp32.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cwchar>
#include <iterator>
#include <utility>
#include <vector>

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

uint64_t TimeValue(const FILETIME& time) {
  return (static_cast<uint64_t>(time.dwHighDateTime) << 32) |
         time.dwLowDateTime;
}

DWORD PriorityValue(const std::string& name) {
  if (name == "idle") return IDLE_PRIORITY_CLASS;
  if (name == "belowNormal") return BELOW_NORMAL_PRIORITY_CLASS;
  if (name == "normal") return NORMAL_PRIORITY_CLASS;
  if (name == "aboveNormal") return ABOVE_NORMAL_PRIORITY_CLASS;
  if (name == "high") return HIGH_PRIORITY_CLASS;
  return 0;
}

std::string PriorityName(DWORD priority) {
  switch (priority) {
    case IDLE_PRIORITY_CLASS: return "idle";
    case BELOW_NORMAL_PRIORITY_CLASS: return "belowNormal";
    case NORMAL_PRIORITY_CLASS: return "normal";
    case ABOVE_NORMAL_PRIORITY_CLASS: return "aboveNormal";
    case HIGH_PRIORITY_CLASS: return "high";
    default: return "unknown";
  }
}

const EncodableValue* Argument(const EncodableMap& arguments,
                               const char* name) {
  const auto found = arguments.find(EncodableValue(name));
  return found == arguments.end() ? nullptr : &found->second;
}

std::string StringArgument(const EncodableMap& arguments, const char* name) {
  const auto* value = Argument(arguments, name);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}

DWORD ProcessArgument(const EncodableMap& arguments) {
  const auto* value = Argument(arguments, "pid");
  int64_t pid = 0;
  if (value) {
    if (const auto* number32 = std::get_if<int32_t>(value)) pid = *number32;
    else if (const auto* number64 = std::get_if<int64_t>(value)) pid = *number64;
  }
  return pid > 0 && pid <= MAXDWORD ? static_cast<DWORD>(pid) : 0;
}

struct ProcessHandle {
  HANDLE handle;
  uint64_t created;
  bool is_java = false;

  ProcessHandle(HANDLE value, uint64_t creation)
      : handle(value), created(creation) {
    wchar_t image[32768] = {};
    DWORD length = static_cast<DWORD>(std::size(image));
    if (QueryFullProcessImageNameW(handle, 0, image, &length)) {
      const auto* separator = wcsrchr(image, L'\\');
      const auto* name = separator ? separator + 1 : image;
      is_java = _wcsicmp(name, L"java.exe") == 0 ||
                _wcsicmp(name, L"javaw.exe") == 0;
    }
  }
  ~ProcessHandle() { CloseHandle(handle); }
  ProcessHandle(const ProcessHandle&) = delete;
  ProcessHandle& operator=(const ProcessHandle&) = delete;
};

std::unique_ptr<ProcessHandle> OpenGameProcess(DWORD pid) {
  HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                 PROCESS_SET_INFORMATION | SYNCHRONIZE,
                             FALSE, pid);
  if (!handle) {
    // Still track its identity and descendants when changing priority is denied.
    handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                         FALSE, pid);
  }
  if (!handle) return nullptr;
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(handle, &created, &exited, &kernel, &user)) {
    const DWORD error = GetLastError();
    CloseHandle(handle);
    SetLastError(error);
    return nullptr;
  }
  return std::make_unique<ProcessHandle>(handle, TimeValue(created));
}
}  // namespace

struct GameProcessPriorities::Session {
  DWORD root;
  DWORD priority;
  std::unordered_map<DWORD, std::unique_ptr<ProcessHandle>> processes;

  Session(DWORD pid, DWORD value, std::unique_ptr<ProcessHandle> process)
      : root(pid), priority(value) {
    processes.emplace(pid, std::move(process));
  }

  EncodableMap Apply() {
    DWORD discovery_error = 0;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
      discovery_error = GetLastError();
    } else {
      std::vector<std::pair<DWORD, DWORD>> children;
      PROCESSENTRY32W entry = {};
      entry.dwSize = sizeof(entry);
      if (Process32FirstW(snapshot, &entry)) {
        do {
          children.emplace_back(entry.th32ProcessID, entry.th32ParentProcessID);
        } while (Process32NextW(snapshot, &entry));
      } else {
        discovery_error = GetLastError();
      }
      CloseHandle(snapshot);
      bool changed;
      do {
        changed = false;
        for (const auto& child : children) {
          if (processes.count(child.first)) continue;
          const auto parent = processes.find(child.second);
          if (parent == processes.end()) continue;
          auto process = OpenGameProcess(child.first);
          if (!process || process->created < parent->second->created) continue;
          FILETIME created, exited, kernel, user;
          if (!GetProcessTimes(parent->second->handle, &created, &exited,
                               &kernel, &user)) continue;
          // A recycled parent PID must never include an unrelated game/client.
          if (TimeValue(exited) != 0 && process->created > TimeValue(exited)) {
            continue;
          }
          processes.emplace(child.first, std::move(process));
          changed = true;
        }
      } while (changed);
    }

    EncodableList results;
    for (const auto& entry : processes) {
      const auto& process = entry.second;
      if (entry.first != root && !process->is_java) continue;
      if (WaitForSingleObject(process->handle, 0) != WAIT_TIMEOUT) continue;
      bool success = SetPriorityClass(process->handle, priority) != FALSE;
      DWORD error = success ? 0 : GetLastError();
      const DWORD actual = GetPriorityClass(process->handle);
      if (success && actual == 0) {
        success = false;
        error = GetLastError();
      } else if (success && actual != priority) {
        success = false;
        error = ERROR_INVALID_DATA;
      }
      results.emplace_back(EncodableMap{
          {EncodableValue("pid"), EncodableValue(static_cast<int64_t>(entry.first))},
          {EncodableValue("actual"), EncodableValue(PriorityName(actual))},
          {EncodableValue("success"), EncodableValue(success)},
          {EncodableValue("error"), EncodableValue(static_cast<int64_t>(error))},
      });
    }
    EncodableMap result{{EncodableValue("processes"), EncodableValue(results)}};
    if (discovery_error != 0) {
      result.emplace(EncodableValue("discoveryError"),
                     EncodableValue(static_cast<int64_t>(discovery_error)));
    }
    return result;
  }
};

GameProcessPriorities::GameProcessPriorities(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "fyl/game_process_priority",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "begin" && call.method_name() != "finish") {
      result->NotImplemented();
      return;
    }
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    if (!arguments) {
      result->Error("invalid_arguments", "Expected a game process session.");
      return;
    }
    const auto id = StringArgument(*arguments, "id");
    if (id.empty()) {
      result->Error("invalid_session", "Missing game process session ID.");
      return;
    }
    if (call.method_name() == "begin") {
      const DWORD pid = ProcessArgument(*arguments);
      const DWORD priority = PriorityValue(StringArgument(*arguments, "priority"));
      if (!pid || !priority || sessions_.count(id)) {
        result->Error("invalid_priority", "Invalid game PID, priority or session.");
        return;
      }
      auto process = OpenGameProcess(pid);
      if (!process) {
        result->Error("open_process_failed", std::to_string(GetLastError()));
        return;
      }
      auto session = std::make_unique<Session>(pid, priority, std::move(process));
      const auto response = session->Apply();
      sessions_.emplace(id, std::move(session));
      result->Success(EncodableValue(response));
    } else {
      const auto session = sessions_.find(id);
      if (session == sessions_.end()) {
        result->Success(EncodableValue(EncodableMap{}));
        return;
      }
      const auto response = session->second->Apply();
      sessions_.erase(session);
      result->Success(EncodableValue(response));
    }
  });
}

GameProcessPriorities::~GameProcessPriorities() {
  channel_->SetMethodCallHandler(nullptr);
}
