# touchid-paste

A macOS command-line tool that auto-fills passwords into your terminal using Touch ID. Press a keyboard shortcut, authenticate with your fingerprint, and the password gets typed into the active terminal window.

Built for quickly authenticating SSH sessions and sudo prompts without manually typing passwords.

## Requirements

- macOS with Touch ID (MacBook Pro/Air with Touch ID, or Apple Silicon Mac with Magic Keyboard with Touch ID)
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

### 1. Clone and compile

```bash
git clone https://github.com/CollinSOik/touchid-paste.git
cd touchid-paste
swiftc main.swift -o touchid-paste -framework LocalAuthentication -framework Security -framework AppKit -O
```

### 2. Install the binary

```bash
mkdir -p ~/.local/bin
cp touchid-paste ~/.local/bin/touchid-paste
chmod 755 ~/.local/bin/touchid-paste
```

Make sure `~/.local/bin` is in your `PATH`. Add this to your `~/.zshrc` if it isn't:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### 3. Store your password

```bash
touchid-paste setup
```

You'll be prompted to enter and confirm your password. Input is hidden (no characters displayed). A Touch ID prompt may appear to authorize storing the item in your Keychain.

### 4. Set up a keyboard shortcut

#### Option A: Automator Quick Action (no extra software)

1. Open **Automator** (`/System/Applications/Automator.app`)
2. Create a new **Quick Action**
3. Set **"Workflow receives"** to **no input** in **any application**
4. Add a **Run Shell Script** action with:
   ```bash
   export PATH="$HOME/.local/bin:$PATH"
   touchid-paste 2>/tmp/touchid-paste-error.log
   ```
5. Save as **"TouchID SSH Paste"**
6. Go to **System Settings > Keyboard > Keyboard Shortcuts > Services**
7. Find **"TouchID SSH Paste"** under General and assign your shortcut (e.g. **Ctrl+Option+P**)

#### Option B: Raycast Script Command

Create `~/.config/raycast/scripts/touchid-paste.sh`:

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Touch ID Paste Password
# @raycast.mode silent
# @raycast.packageName Security

# Optional parameters:
# @raycast.icon 🔐

export PATH="$HOME/.local/bin:$PATH"
touchid-paste 2>/dev/null
```

Then in Raycast: **Extensions > Script Commands > Add Script Directory**, point to `~/.config/raycast/scripts/`, and assign a hotkey to the command.

### 5. Grant Accessibility permissions

The first time you trigger the shortcut, macOS will ask you to grant **Accessibility** access to Automator (or Raycast). Go to **System Settings > Privacy & Security > Accessibility** and enable it. This is required for the tool to simulate the Cmd+V keystroke.

> **Security note:** Accessibility access is a powerful permission — any app with it can simulate keystrokes and observe UI elements. Periodically review which apps have Accessibility access in **System Settings > Privacy & Security > Accessibility** and remove any you no longer use.

## Usage

| Command | Description |
|---------|-------------|
| `touchid-paste` | Authenticate with Touch ID, paste password + press Enter |
| `touchid-paste setup` | Store a new password (replaces any existing one) |
| `touchid-paste delete` | Remove the stored password from Keychain (prompts for confirmation) |
| `touchid-paste check` | Check if a password is currently stored (exit code 0 = yes) |
| `touchid-paste -h` | Show help |
| `--account <name>` | Use a named account instead of the default (can combine with any command) |

### Typical workflow

1. SSH into a server: `ssh user@192.168.1.100`
2. When the password prompt appears, press your keyboard shortcut (e.g. **Ctrl+Option+P**)
3. Touch ID dialog appears — place your finger on the sensor
4. Password is pasted and Enter is pressed automatically
5. You're logged in

This also works for `sudo` prompts and any other password field in your terminal.

### Multiple accounts

Use `--account` to store separate passwords for different services:

```bash
# Store passwords for different accounts
touchid-paste --account work setup
touchid-paste --account homelab setup

# Paste a specific account's password
touchid-paste --account work
touchid-paste --account homelab
```

Without `--account`, the tool uses a default account. Each account is stored as a separate Keychain item.

## How your password is protected

### Keychain encryption with biometric access control

Your password is stored in the macOS Keychain — the same encrypted store that Safari, Mail, and 1Password use. It is **not** saved to any file on disk.

The Keychain item is created with two critical flags:

- **`SecAccessControlCreateWithFlags` with `.biometryCurrentSet`**: The password can *only* be decrypted after a successful Touch ID scan. This is enforced at the hardware level by the Secure Enclave. No software process — not even running as root — can read the password without biometric authentication. The `security` command-line tool cannot access it. If you try `security find-generic-password -s com.touchid-paste.ssh-password -w`, it will fail.

- **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**: The Keychain item is tied to this specific Mac. It cannot be extracted from backups, synced via iCloud Keychain, or migrated to another device.

### What `.biometryCurrentSet` means

The "CurrentSet" part is important: if your fingerprint enrollment changes (you add or remove a fingerprint), the Keychain item is **automatically invalidated**. This prevents an attacker who gains physical access from enrolling their own fingerprint to unlock your password. You would need to re-run `touchid-paste setup` after any fingerprint change.

### Clipboard handling

When activated, the tool:

1. Saves your current clipboard contents
2. Places the password on the clipboard
3. Simulates Cmd+V to paste into the frontmost app
4. Simulates Enter to submit
5. After 0.5 seconds, clears the password from the clipboard and restores your previous clipboard contents

The password is on the clipboard for approximately half a second.

### What is NOT stored or logged

- The password is never written to any file on disk
- The password never appears in process arguments (no `ps aux` exposure)
- The password is never set as an environment variable
- No logs are written containing the password
- stderr output only contains error messages, never the password itself

### Threat model summary

| Threat | Protected? | How |
|--------|-----------|-----|
| Password at rest on disk | Yes | Stored only in Keychain (Secure Enclave encrypted) |
| Other processes reading the password | Yes | Biometric ACL blocks all non-Touch ID access |
| Password left in clipboard | Yes | Cleared after 0.5s, previous contents restored |
| Password left on clipboard after paste failure | Yes | Immediately cleared if AppleScript fails |
| Password in process args or env vars | Yes | Never exposed in either |
| Keychain metadata leaking account info | Yes | Generic default account name; user-chosen with `--account` |
| Device theft | Yes | Biometric + device-only flags prevent extraction |
| Fingerprint enrollment tampering | Yes | `.biometryCurrentSet` invalidates on enrollment change |
| Clipboard monitoring during 0.5s window | No | Same limitation as 1Password — inherent to clipboard-based paste |
| Root-level memory inspection | No | Out of scope — root access implies full system compromise |

## Troubleshooting

**Touch ID prompt doesn't appear:**
Make sure the binary is compiled on the same Mac you're running it on. CLI binaries on Apple Silicon Macs can use `LocalAuthentication` without additional code signing, but if Touch ID doesn't trigger, try ad-hoc signing:

```bash
codesign --force --sign - ~/.local/bin/touchid-paste
```

**"No password stored" error:**
Run `touchid-paste setup` to store a password first.

**Password doesn't paste into the terminal:**
Check that Accessibility permissions are granted to Automator/Raycast in **System Settings > Privacy & Security > Accessibility**.

**Keyboard shortcut doesn't work:**
After creating the Automator Quick Action, you may need to log out and back in (or restart) for the service to appear in Keyboard Shortcuts settings. Also verify it's enabled with a checkmark in the Services list.

**"Passwords do not match" during setup:**
The confirmation password must match exactly. Re-run `touchid-paste setup`.

## Upgrading

If you are upgrading from a version that used a hardcoded account name, your existing Keychain entry may use the old account identifier. Re-run `touchid-paste setup` to store your password under the new default account, or use `--account` to migrate to a named account.

## Security

To report a security vulnerability, please open a GitHub issue or email the repository owner directly. Do not include sensitive details (passwords, Keychain data) in public reports.

## Uninstalling

```bash
# Remove the binary
rm ~/.local/bin/touchid-paste

# Remove the stored password from Keychain
# (or run touchid-paste delete before removing the binary)
security delete-generic-password -s com.touchid-paste.ssh-password

# Remove the Automator Quick Action (if used)
rm -rf ~/Library/Services/"TouchID SSH Paste.workflow"
```

Then remove the keyboard shortcut from System Settings.

## License

MIT
