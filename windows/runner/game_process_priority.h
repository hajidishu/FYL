#ifndef RUNNER_GAME_PROCESS_PRIORITY_H_
#define RUNNER_GAME_PROCESS_PRIORITY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <unordered_map>

class GameProcessPriorities {
 public:
  explicit GameProcessPriorities(flutter::BinaryMessenger* messenger);
  ~GameProcessPriorities();

 private:
  struct Session;
  std::unordered_map<std::string, std::unique_ptr<Session>> sessions_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_GAME_PROCESS_PRIORITY_H_
