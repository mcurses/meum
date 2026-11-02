// `meum` CLI entry point. All logic lives in MeumControl (CLI.swift) so it is testable.
import Foundation
import MeumControl

exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
