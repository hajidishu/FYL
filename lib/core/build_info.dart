const launcherVersion = String.fromEnvironment(
  'FYL_VERSION',
  defaultValue: 'development',
);

const launcherIsRelease = bool.fromEnvironment('FYL_IS_RELEASE');

// TODO(multiplayer): finish real-network validation before enabling by default.
// Keep the UI and network helper behind the same explicit build-time flag.
const launcherMultiplayerEnabled = bool.fromEnvironment(
  'FYL_ENABLE_MULTIPLAYER',
);
