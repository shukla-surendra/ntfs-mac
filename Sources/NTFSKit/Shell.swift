import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

public enum Shell {
    /// Runs an executable with explicit arguments (no shell interpolation).
    @discardableResult
    public static func run(_ path: String, _ args: [String]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return ShellResult(status: 127, stdout: Data(), stderr: "\(error)")
        }
        // Drain both pipes before waiting to avoid pipe-buffer deadlocks.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, stdout: outData,
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}
