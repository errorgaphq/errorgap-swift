import Foundation

#if canImport(Darwin)
import Darwin

/// Fatal signals: memory faults, aborts, and the traps the Swift runtime
/// raises for `fatalError`, a force-unwrapped `nil`, an out-of-range index or
/// an overflow. None of them reach `NSSetUncaughtExceptionHandler`.
///
/// A signal handler may do almost nothing safely: no allocation, no locks, no
/// Swift runtime calls, so certainly no network. The handler below only
/// writes the signal number and the raw stack to a file that was opened in
/// advance, then lets the signal take its normal course. The next launch
/// turns that file into a notice (`ErrorgapClient.sendStoredCrashes`).
enum SignalCrashes {
    static let filePrefix = "signal-"
    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
    private static let lock = NSLock()

    /// Start capturing fatal signals into `folder`. Safe to call again: the
    /// file descriptor is replaced, the handlers stay.
    /// Returns the name of the file this launch writes to.
    @discardableResult
    static func install(folder: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(filePrefix)\(UUID().uuidString).txt"
        let descriptor = open(folder.appendingPathComponent(name).path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return nil }
        if signalFile >= 0 { close(signalFile) }
        signalFile = descriptor

        guard !installed else { return name }
        installed = true
        frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxFrames))
        header = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        previous = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        previous?.initialize(repeating: sigaction(), count: Int(NSIG))

        // No alternate signal stack: `backtrace` refuses to walk from one, and
        // a crash with no stack is worth little. The cost is that a stack
        // overflow, which leaves no room to run the handler, is not recorded.
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = handleFatalSignal
            action.sa_flags = 0
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, previous?.advanced(by: Int(signal)))
        }
        return name
    }

    /// The name of a signal number written by the handler.
    static func name(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(signal)"
        }
    }

    /// Parse a file the handler wrote: the signal, then one stack line per
    /// frame. Returns nil for an empty file (a launch that did not crash).
    static func parse(_ text: String) -> (signal: Int32, symbols: [String])? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("signal "),
              let signal = Int32(first.dropFirst("signal ".count))
        else { return nil }
        lines.removeFirst()
        // The first frames are the handler itself and the signal trampoline.
        let symbols = lines.filter { !$0.contains("handleFatalSignal") && !$0.contains("_sigtramp") }
        return (signal, symbols.map(demangled))
    }

    /// Swift symbols arrive mangled (`$s5MyApp4loadyyF`); make them readable
    /// when the runtime's demangler is available.
    private static func demangled(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return line }
        let symbol = String(parts[3])
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S"),
              let readable = demangle(symbol)
        else { return line }
        return line.replacingOccurrences(of: symbol, with: readable)
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static func demangle(_ symbol: String) -> String? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        let function = unsafeBitCast(address, to: Demangler.self)
        return symbol.withCString { pointer in
            guard let result = function(pointer, strlen(pointer), nil, nil, 0) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

// Everything the handler touches is allocated before a signal can arrive.
nonisolated(unsafe) private var installed = false
nonisolated(unsafe) private var signalFile: Int32 = -1
nonisolated(unsafe) private var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
nonisolated(unsafe) private var header: UnsafeMutablePointer<UInt8>?
nonisolated(unsafe) private var previous: UnsafeMutablePointer<sigaction>?
private let maxFrames: Int32 = 128

private func handleFatalSignal(_ signal: Int32) {
    if signalFile >= 0, let frames, let header {
        // "signal NN\n", built by hand: no formatting, no allocation.
        let prefix: StaticString = "signal "
        var length = 0
        prefix.withUTF8Buffer { bytes in
            for byte in bytes {
                header[length] = byte
                length += 1
            }
        }
        if signal >= 10 {
            header[length] = UInt8(48 + (signal / 10) % 10)
            length += 1
        }
        header[length] = UInt8(48 + signal % 10)
        header[length + 1] = 10
        _ = write(signalFile, header, length + 2)

        let count = backtrace(frames, maxFrames)
        backtrace_symbols_fd(frames, count, signalFile)
        close(signalFile)
        signalFile = -1
    }
    // Hand the signal back to whoever had it before (another crash reporter,
    // or the default action that ends the process) and raise it again.
    if let previous {
        sigaction(signal, previous.advanced(by: Int(signal)), nil)
    } else {
        Darwin.signal(signal, SIG_DFL)
    }
    raise(signal)
}
#endif
