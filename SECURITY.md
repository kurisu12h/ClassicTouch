# Security

## Reporting a vulnerability

Please do **not** put vulnerability details in a public issue. Use GitHub's private reporting: **Security → Report a vulnerability** on the repository page. Maintainers will confirm as soon as they can and publish the details together with the fix.

## Scope

We mainly care about:

- **Guest escapes**: a program in the emulated iOS reading or writing the host app's memory, or running host code, through a device model, the GL bridge (`gles-host`, `guest-gles`), guest services (`QEMU_CALL`) or the JIT.
- **Imports**: out-of-bounds access or path traversal (writing outside the app's directory) when the app unpacks a `.ctpack` or another imported file.
- **Leaks**: the app or scripts writing UDIDs, pairing files or signing details into logs, screenshots or the repository.

Vulnerabilities in the guest systems themselves (iOS versions decades old) are out of scope: they are what is being emulated, not this project's code.

## Supported versions

There is no release yet; only the latest code on the main branch is fixed.
