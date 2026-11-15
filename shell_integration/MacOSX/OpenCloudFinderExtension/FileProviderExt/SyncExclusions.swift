/*
 * Copyright (C) 2026 OpenCloud GmbH
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import Foundation

/// The desktop client's ignore list (system sync-exclude.lst plus the user's list),
/// matched like the sync engine's ExcludedFiles:
/// - `#` starts a comment; a leading `]` marks "excluded, may be deleted" (still excluded).
/// - A trailing `/` restricts a pattern to directories.
/// - Patterns without `/` match the name of the item or of any parent folder;
///   patterns with `/` match the path relative to the space root, where `*` does not cross `/`.
struct SyncExclusions: Equatable {
    private struct Pattern: Equatable {
        let glob: String
        let directoriesOnly: Bool
        let matchesPath: Bool
    }

    private let patterns: [Pattern]
    let lines: [String]

    static let appGroupKey = "fp_exclude_patterns"

    init(lines: [String]) {
        self.lines = lines
        patterns = lines.compactMap { raw in
            var line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if line.hasPrefix("]") { line.removeFirst() }
            // The list writes control characters escaped, e.g. "Icon\r" for the macOS folder icon file.
            line = line.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
            let directoriesOnly = line.hasSuffix("/")
            if directoriesOnly { line.removeLast() }
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty else { return nil }
            return Pattern(glob: line, directoriesOnly: directoriesOnly, matchesPath: line.contains("/"))
        }
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// `path` is relative to the space root, e.g. "/Documents/report.docx".
    func isExcluded(path: String, isDirectory: Bool) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        for pattern in patterns {
            if pattern.matchesPath {
                // A full-path pattern also excludes everything below a matching folder.
                for depth in 1...components.count {
                    let isLast = depth == components.count
                    if pattern.directoriesOnly && isLast && !isDirectory { continue }
                    if Self.matches(pattern.glob, components[0..<depth].joined(separator: "/"), pathname: true) { return true }
                }
            } else {
                for (index, name) in components.enumerated() {
                    let isLast = index == components.count - 1
                    if pattern.directoriesOnly && isLast && !isDirectory { continue }
                    if Self.matches(pattern.glob, name, pathname: false) { return true }
                }
            }
        }
        return false
    }

    private static func matches(_ pattern: String, _ string: String, pathname: Bool) -> Bool {
        fnmatch(pattern, string, pathname ? FNM_PATHNAME : 0) == 0
    }
}
