import Foundation

@main
enum Diff3SpikeTests {
    static func main() {
        testNonOverlappingChangesMergeAutomatically()
        testOverlappingChangesProduceConflict()
        testIdenticalChangesAreAppliedOnce()
        testSameAnchorInsertionsConflictDeterministically()
        testDeleteAndReplaceOverlap()
        testRepeatedLinesHaveStableOutput()
        testOneSidedDeletionAtEnd()
        print("Diff3SpikeTests: 7 passed")
    }

    private static func testNonOverlappingChangesMergeAutomatically() {
        let result = Diff3.merge(
            base: "alpha\nbeta\ngamma\n",
            local: "alpha local\nbeta\ngamma\n",
            remote: "alpha\nbeta\ngamma remote\n"
        )

        expectEqual(
            result,
            MergeResult(
                text: "alpha local\nbeta\ngamma remote\n",
                conflicts: []
            ),
            test: #function
        )
    }

    private static func testOverlappingChangesProduceConflict() {
        let result = Diff3.merge(
            base: "alpha\nbeta\ngamma\n",
            local: "alpha\nlocal beta\ngamma\n",
            remote: "alpha\nremote beta\ngamma\n"
        )

        expectEqual(result.conflicts.count, 1, test: #function)
        expectEqual(
            result.text,
            "alpha\n<<<<<<< LOCAL\nlocal beta\n||||||| BASE\nbeta\n=======\nremote beta\n>>>>>>> ICLOUD\ngamma\n",
            test: #function
        )
    }

    private static func testIdenticalChangesAreAppliedOnce() {
        let result = Diff3.merge(
            base: "one\ntwo\n",
            local: "one\nshared\n",
            remote: "one\nshared\n"
        )

        expectEqual(result, MergeResult(text: "one\nshared\n", conflicts: []), test: #function)
    }

    private static func testSameAnchorInsertionsConflictDeterministically() {
        let result = Diff3.merge(
            base: "one\ntwo\n",
            local: "one\nlocal\ntwo\n",
            remote: "one\nremote\ntwo\n"
        )

        expectEqual(result.conflicts.count, 1, test: #function)
        expectEqual(
            result.text,
            "one\n<<<<<<< LOCAL\nlocal\n||||||| BASE\n=======\nremote\n>>>>>>> ICLOUD\ntwo\n",
            test: #function
        )
    }

    private static func testDeleteAndReplaceOverlap() {
        let result = Diff3.merge(
            base: "one\ntwo\nthree\nfour\n",
            local: "one\nfour\n",
            remote: "one\ntwo\nremote three\nfour\n"
        )

        expectEqual(result.conflicts.count, 1, test: #function)
        expectEqual(result.conflicts[0].base, "two\nthree\n", test: #function)
    }

    private static func testRepeatedLinesHaveStableOutput() {
        let first = Diff3.merge(
            base: "item\nitem\nend\n",
            local: "local\nitem\nend\n",
            remote: "item\nitem\nremote\n"
        )
        let second = Diff3.merge(
            base: "item\nitem\nend\n",
            local: "local\nitem\nend\n",
            remote: "item\nitem\nremote\n"
        )

        expectEqual(first, second, test: #function)
        expectEqual(first.text, "local\nitem\nremote\n", test: #function)
    }

    private static func testOneSidedDeletionAtEnd() {
        let result = Diff3.merge(
            base: "one\ntwo\n",
            local: "one\n",
            remote: "one\ntwo\n"
        )

        expectEqual(result, MergeResult(text: "one\n", conflicts: []), test: #function)
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        test: String
    ) {
        guard actual == expected else {
            fputs("FAIL \(test)\nexpected: \(expected)\nactual: \(actual)\n", stderr)
            exit(1)
        }
    }
}
