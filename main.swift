import Foundation
import LocalAuthentication
import Security
import AppKit

// MARK: - Constants

let keychainService = "com.touchid-paste.ssh-password"
let keychainAccount = "proxmox-vms"

// MARK: - Keychain Operations

func createBiometricAccessControl() -> SecAccessControl? {
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &error
    )
    if let error = error {
        fputs("Error creating access control: \(error.takeRetainedValue())\n", stderr)
        return nil
    }
    return access
}

func storePassword(_ password: String) -> Bool {
    // Delete existing item first (ignore error if not found)
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    guard let accessControl = createBiometricAccessControl() else {
        return false
    }

    let context = LAContext()
    context.localizedReason = "Store password in Keychain"

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecAttrLabel as String: "SSH/sudo password (touchid-paste)",
        kSecValueData as String: password.data(using: .utf8)!,
        kSecAttrAccessControl as String: accessControl,
        kSecUseAuthenticationContext as String: context,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess {
        fputs("Keychain store failed: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        return false
    }
    return true
}

func retrievePassword() -> String? {
    let context = LAContext()
    context.localizedReason = "Access SSH password"

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecUseAuthenticationContext as String: context,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess,
          let data = result as? Data,
          let password = String(data: data, encoding: .utf8) else {
        if status == errSecItemNotFound {
            fputs("No password stored. Run 'touchid-paste setup' first.\n", stderr)
        } else if status == errSecUserCanceled {
            fputs("Touch ID authentication was canceled.\n", stderr)
        } else if status == errSecAuthFailed {
            fputs("Touch ID authentication failed.\n", stderr)
        } else {
            fputs("Keychain read failed: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        }
        return nil
    }
    return password
}

func deletePassword() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
}

func checkPasswordExists() -> Bool {
    let context = LAContext()
    context.interactionNotAllowed = true

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecUseAuthenticationContext as String: context,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
}

// MARK: - Paste Action

func pastePassword(_ password: String) {
    let pasteboard = NSPasteboard.general

    // Save current clipboard content
    let oldContents = pasteboard.string(forType: .string)

    // Put password on clipboard
    pasteboard.clearContents()
    pasteboard.setString(password, forType: .string)

    // Small delay to ensure clipboard is ready
    usleep(50_000) // 50ms

    // Simulate Cmd+V paste then Enter via AppleScript
    let script = """
    tell application "System Events"
        keystroke "v" using command down
        delay 0.1
        keystroke return
    end tell
    """

    let appleScript = NSAppleScript(source: script)
    var errorInfo: NSDictionary?
    appleScript?.executeAndReturnError(&errorInfo)

    if let errorInfo = errorInfo {
        fputs("AppleScript error: \(errorInfo)\n", stderr)
    }

    // Clear the password from clipboard after a short delay, restore old contents
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        pasteboard.clearContents()
        if let oldContents = oldContents {
            pasteboard.setString(oldContents, forType: .string)
        }
        exit(0)
    }
}

// MARK: - Secure Input

func readSecureInput(prompt: String) -> String? {
    fputs(prompt, stderr)

    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

    let password = readLine(strippingNewline: true)

    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
    fputs("\n", stderr)

    return password
}

// MARK: - Main

let args = CommandLine.arguments

if args.count > 1 && args[1] == "setup" {
    fputs("touchid-paste: Store SSH/sudo password in Keychain (Touch ID protected)\n", stderr)

    guard let password = readSecureInput(prompt: "Enter password: ") else {
        fputs("Error reading password.\n", stderr)
        exit(1)
    }
    guard !password.isEmpty else {
        fputs("Password cannot be empty.\n", stderr)
        exit(1)
    }
    guard let confirm = readSecureInput(prompt: "Confirm password: ") else {
        fputs("Error reading confirmation.\n", stderr)
        exit(1)
    }
    guard password == confirm else {
        fputs("Passwords do not match.\n", stderr)
        exit(1)
    }

    if storePassword(password) {
        fputs("Password stored successfully with Touch ID protection.\n", stderr)
        exit(0)
    } else {
        fputs("Failed to store password.\n", stderr)
        exit(1)
    }

} else if args.count > 1 && args[1] == "delete" {
    if deletePassword() {
        fputs("Password deleted from Keychain.\n", stderr)
        exit(0)
    } else {
        fputs("Failed to delete password.\n", stderr)
        exit(1)
    }

} else if args.count > 1 && args[1] == "check" {
    if checkPasswordExists() {
        fputs("Password is stored.\n", stderr)
        exit(0)
    } else {
        fputs("No password stored.\n", stderr)
        exit(1)
    }

} else if args.count > 1 && (args[1] == "-h" || args[1] == "--help") {
    fputs("""
    Usage: touchid-paste [command]

    Commands:
      (none)    Authenticate with Touch ID, paste password, press Enter
      setup     Store a new password in Keychain (Touch ID protected)
      delete    Remove stored password from Keychain
      check     Check if a password is stored
      -h        Show this help

    """, stderr)
    exit(0)

} else {
    // Default: authenticate + paste
    guard let password = retrievePassword() else {
        exit(1)
    }

    pastePassword(password)

    // Keep run loop alive for the delayed clipboard clear
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
}
