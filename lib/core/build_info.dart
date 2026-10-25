const launcherVersion = String.fromEnvironment(
  'FYL_VERSION',
  defaultValue: 'development',
);

const launcherIsRelease = bool.fromEnvironment('FYL_IS_RELEASE');
