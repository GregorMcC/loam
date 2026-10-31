import Testing

@testable import LoamKit

@Suite struct CLIArgumentsTests {
    let program = "/Applications/Loam.app/Contents/MacOS/Loam"
    let bundled = "/Applications/Loam.app/Contents/Helpers/loam"

    func refusal(_ arguments: [String]) -> String? {
        CLIArguments.refusal(arguments: [program] + arguments, bundledCLI: bundled)
    }

    @Test func aCLICommandIsRefusedWithOneLineThatNamesTheBundledCLI() throws {
        let line = try #require(refusal(["export", "--changes", "--json"]))
        #expect(line == "This is the Loam app, not the loam CLI. Run the CLI at \(bundled).\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(CLIArguments.exitStatus == 2)
    }

    @Test(arguments: [["list"], ["run", "start"], ["version", "--json"], ["anything"], [""]])
    func anyFirstWordIsRefused(_ arguments: [String]) {
        #expect(refusal(arguments) != nil)
    }

    @Test func noArgumentsStartTheApp() {
        #expect(refusal([]) == nil)
        #expect(CLIArguments.refusal(arguments: [], bundledCLI: bundled) == nil)
    }

    @Test(arguments: [["-NSDocumentRevisionsDebugMode", "YES"], ["-psn_0_12345"], ["-ApplePersistenceIgnoreState", "YES"]])
    func macOSLaunchArgumentsStartTheApp(_ arguments: [String]) {
        #expect(refusal(arguments) == nil)
    }
}
