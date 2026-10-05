import Darwin
import Foundation

do {
    exit(try CLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
} catch {
    TerminalOutput.error(String(describing: error))
    exit(CLI.exitCode(for: error))
}
