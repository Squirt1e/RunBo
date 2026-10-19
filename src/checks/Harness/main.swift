import Foundation
import Core

// Checks: a dependency-free self-test harness for Core.
//
//   swift build --scratch-path .build-checks --product runbo-checks
//   swift run --scratch-path .build-checks runbo-checks [name-substring]
//
// Every check prints exactly one `PASS <name>` / `FAIL <name>: <reason>` line, followed
// by a `N passed, M failed` summary. The process exits 1 when any check failed.

registerMarkerParserChecks()
registerEnvironmentParserChecks()
registerDatabaseChecks()
registerStoreChecks()
registerCardTagChecks()
registerTagPickerLayoutChecks()
registerCardReorderingChecks()
registerCardCopyChecks()
registerRetentionChecks()
registerShellShimChecks()
registerPTYChecks()
registerPresentationChecks()
registerPanelLayoutChecks()
registerTerminalFontSizeChecks()
registerDeleteBurstChecks()
registerCardDisplayChecks()
registerDirectoryCompletionChecks()
registerFileBrowserChecks()
registerSplitRulesChecks()
registerSidebarChecks()
registerHomeProjectionChecks()
registerSessionEngineChecks()

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
exit(runChecks(filter: filter))
