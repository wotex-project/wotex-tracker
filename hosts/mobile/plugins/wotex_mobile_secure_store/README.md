# WoTEx mobile secure store

This host-local Mob plugin exposes two closed iOS Keychain slots: the current
service credential envelope and a random installation identifier. Values use
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, are not synchronized through
iCloud Keychain and do not migrate through backups.

The native NIF is statically linked by Mob for an iOS build. On an ordinary
development host, the wrapper returns `{:error, :unavailable}`. The plugin does
not provide an ordinary-file or preferences fallback.
