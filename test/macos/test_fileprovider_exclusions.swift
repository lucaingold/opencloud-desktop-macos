import Foundation

@main struct ExclusionTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func main() throws {
        let listURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let lines = try String(contentsOf: listURL, encoding: .utf8).components(separatedBy: "\n")
        let system = SyncExclusions(lines: lines)
        check(!system.isEmpty, "the system ignore list loads")
        for path in ["/.DS_Store", "/Projects/.DS_Store", "/Docs/~$report.docx", "/Docs/.~lock.report.odt#",
                     "/Downloads/video.mp4.part", "/a/b.crdownload", "/notes.txt~", "/Icon\r", "/x/._resource"] {
            check(system.isExcluded(path: path, isDirectory: false), "\(path.debugDescription) is excluded")
        }
        check(system.isExcluded(path: "/.Trashes/file.txt", isDirectory: false), "items inside an excluded folder are excluded")
        check(system.isExcluded(path: "/Code/app.nosync", isDirectory: true), ".nosync folders stay local")
        check(system.isExcluded(path: "/Code/app.nosync/src/main.swift", isDirectory: false), "items inside a .nosync folder stay local")
        check(system.isExcluded(path: "/cache.nosync", isDirectory: false), ".nosync files stay local")
        check(!system.isExcluded(path: "/Docs/nosync-notes.txt", isDirectory: false), "nosync elsewhere in a name is synced")
        for path in ["/report.docx", "/Projects/main.swift", "/Photos/IMG_0001.HEIC", "/Docs/lock.txt", "/Icon.png"] {
            check(!system.isExcluded(path: path, isDirectory: false), "\(path) is synced")
        }

        let user = SyncExclusions(lines: ["# comment", "", "build/", "/Projects/secret/*.key", "]*.log"])
        check(user.isExcluded(path: "/app/build", isDirectory: true), "trailing slash excludes directories")
        check(!user.isExcluded(path: "/app/build", isDirectory: false), "trailing slash does not exclude files")
        check(user.isExcluded(path: "/app/build/out.o", isDirectory: false), "items below an excluded directory are excluded")
        check(user.isExcluded(path: "/Projects/secret/api.key", isDirectory: false), "path patterns match from the space root")
        check(!user.isExcluded(path: "/Projects/secret/sub/api.key", isDirectory: false), "* in a path pattern does not cross folders")
        check(!user.isExcluded(path: "/Other/Projects/secret/api.key", isDirectory: false), "path patterns are anchored at the root")
        check(user.isExcluded(path: "/var/server.log", isDirectory: false), "a leading ] still excludes")
        check(SyncExclusions(lines: []).isExcluded(path: "/.DS_Store", isDirectory: false) == false, "an empty list excludes nothing")

        let hidden = SyncExclusions(lines: [], ignoreHiddenFiles: true)
        check(!hidden.isEmpty, "the hidden files rule alone is a rule")
        check(hidden.isExcluded(path: "/.env", isDirectory: false), "hidden files stay local")
        check(hidden.isExcluded(path: "/repo/.git", isDirectory: true), "hidden folders stay local")
        check(hidden.isExcluded(path: "/repo/.git/config", isDirectory: false), "items in hidden folders stay local")
        check(!hidden.isExcluded(path: "/repo/notes.txt", isDirectory: false), "visible files are synced")
        check(!hidden.isExcluded(path: "/repo/v1.2.txt", isDirectory: false), "a dot inside a name is not hidden")
        check(!SyncExclusions(lines: []).isExcluded(path: "/.env", isDirectory: false), "hidden files sync when the user opts in")
        print("FileProvider exclusion tests passed")
    }
}
