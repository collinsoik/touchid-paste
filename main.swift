import Foundation
import LocalAuthentication
import Security
import AppKit

// MARK: - Constants

let keychainService = "com.touchid-paste.ssh-password"
let defaultAccount = "default"

// MARK: - Error Handling

func keychainErrorMessage(_ status: OSStatus) -> String {
    switch status {
    case errSecItemNotFound:
        return "item not found"
    case errSecAuthFailed:
        return "authentication failed"
    case errSecUserCanceled:
        return "user canceled"
    case errSecDuplicateItem:
        return "duplicate item"
    case errSecInteractionNotAllowed:
        return "interaction not allowed"
    case errSecDecode:
        return "unable to decode data"
    default:
        return "error (status \(status))"
    }
}

// MARK: - Keychain Operations

func createBiometricAccessControl() -> SecAccessControl? {
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &error
    )
    if error != nil {
        fputs("Error creating biometric access control.\n", stderr)
        return nil
    }
    return access
}

func storePassword(_ password: String, account: String) -> Bool {
    guard let passwordData = password.data(using: .utf8) else {
        fputs("Error: password contains invalid characters.\n", stderr)
        return false
    }

    // Delete existing item first (ignore error if not found)
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: account,
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
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "SSH/sudo password (touchid-paste)",
        kSecValueData as String: passwordData,
        kSecAttrAccessControl as String: accessControl,
        kSecUseAuthenticationContext as String: context,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess {
        fputs("Keychain store failed: \(keychainErrorMessage(status))\n", stderr)
        return false
    }
    return true
}

func retrievePassword(account: String) -> String? {
    let context = LAContext()
    context.localizedReason = "Access SSH password"

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: account,
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
            fputs("Keychain read failed: \(keychainErrorMessage(status))\n", stderr)
        }
        return nil
    }
    return password
}

func deletePassword(account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
}

func checkPasswordExists(account: String) -> Bool {
    let context = LAContext()
    context.interactionNotAllowed = true

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: account,
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

    func clearAndRestore() {
        pasteboard.clearContents()
        if let oldContents = oldContents {
            pasteboard.setString(oldContents, forType: .string)
        }
    }

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

    if errorInfo != nil {
        clearAndRestore()
        fputs("Failed to paste password. Check Accessibility permissions.\n", stderr)
        exit(1)
    }

    // Clear the password from clipboard after a short delay, restore old contents
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        clearAndRestore()
        CFRunLoopStop(CFRunLoopGetMain())
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

var args = Array(CommandLine.arguments.dropFirst()) // drop program name
var account = defaultAccount

// Parse --account flag before subcommand
if let idx = args.firstIndex(of: "--account") {
    if idx + 1 < args.count {
        account = args[idx + 1]
        args.removeSubrange(idx...idx+1)
    } else {
        fputs("Error: --account requires a value.\n", stderr)
        exit(1)
    }
}

let command = args.first

if command == "setup" {
    fputs("touchid-paste: Store SSH/sudo password in Keychain (Touch ID protected)\n", stderr)
    if account != defaultAccount {
        fputs("Account: \(account)\n", stderr)
    }

    guard let password = readSecureInput(prompt: "Enter password: ") else {
        fputs("Error reading password.\n", stderr)
        exit(1)
    }
    guard !password.isEmpty else {
        fputs("Password cannot be empty.\n", stderr)
        exit(1)
    }
    if password.count < 8 {
        fputs("Warning: password is shorter than 8 characters.\n", stderr)
        fputs("Continue? (y/N): ", stderr)
        guard let response = readLine(strippingNewline: true),
              response.lowercased() == "y" else {
            fputs("Aborted.\n", stderr)
            exit(1)
        }
    }
    guard let confirm = readSecureInput(prompt: "Confirm password: ") else {
        fputs("Error reading confirmation.\n", stderr)
        exit(1)
    }
    guard password == confirm else {
        fputs("Passwords do not match.\n", stderr)
        exit(1)
    }

    if storePassword(password, account: account) {
        fputs("Password stored successfully with Touch ID protection.\n", stderr)
        exit(0)
    } else {
        fputs("Failed to store password.\n", stderr)
        exit(1)
    }

} else if command == "delete" {
    guard checkPasswordExists(account: account) else {
        fputs("No password stored for account '\(account)'.\n", stderr)
        exit(1)
    }
    fputs("Delete stored password for account '\(account)'? (y/N): ", stderr)
    guard let response = readLine(strippingNewline: true),
          response.lowercased() == "y" else {
        fputs("Aborted.\n", stderr)
        exit(0)
    }
    if deletePassword(account: account) {
        fputs("Password deleted from Keychain.\n", stderr)
        exit(0)
    } else {
        fputs("Failed to delete password.\n", stderr)
        exit(1)
    }

} else if command == "check" {
    if checkPasswordExists(account: account) {
        fputs("Password is stored.\n", stderr)
        exit(0)
    } else {
        fputs("No password stored.\n", stderr)
        exit(1)
    }

} else if command == "-h" || command == "--help" {
    fputs("""
    Usage: touchid-paste [--account <name>] [command]

    Options:
      --account <name>  Use a named account (default: "default")

    Commands:
      (none)    Authenticate with Touch ID, paste password, press Enter
      setup     Store a new password in Keychain (Touch ID protected)
      delete    Remove stored password from Keychain
      check     Check if a password is stored
      -h        Show this help

    """, stderr)
    exit(0)

} else if command != nil {
    fputs("Unknown command: \(command!)\n", stderr)
    fputs("Run 'touchid-paste -h' for usage.\n", stderr)
    exit(1)

} else {
    // Default: authenticate + paste
    guard let password = retrievePassword(account: account) else {
        exit(1)
    }

    pastePassword(password)

    // Keep run loop alive for the delayed clipboard clear
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
}
