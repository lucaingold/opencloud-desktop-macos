<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project Overview

OpenCloud Desktop is a Qt-based C++ desktop synchronization client for OpenCloud (Windows, macOS, Linux).

- **Framework**: Qt 6.8+ (Core, Widgets, Network, QML/Quick)
- **Language**: C++20
- **Build System**: CMake 3.18+ with KDE ECM (Extra CMake Modules)
- **Version**: 3.1.7 (see VERSION.cmake)

## Coding Style

- **Formatter**: WebKit-based style, 160 column limit (see .clang-format)
- **Naming**: Qt conventions (camelCase methods, PascalCase classes)
- **Braces**: Attached for control statements, newline for functions/classes/structs
- **Pointers**: `Foo *ptr` (star binds to variable)
- **Logging**: Qt logging categories (`Q_DECLARE_LOGGING_CATEGORY(lcSync)`)

## Development Rules

1. **Read before modifying** — always read files before suggesting changes
2. **Minimal changes** — only what's directly requested, no bonus refactoring
3. **Follow existing patterns** — match style, architecture, and error handling in the same module
4. **Platform-specific code** — check for existing abstractions before adding `#ifdef`s
5. **Delete unused code** — no `_unused` vars, no `// removed` comments
6. **Commit formatting** — use pre-commit hook, don't skip with `--no-verify`

## On-Demand Documentation (ai_docs/)

Load relevant docs before working on specific areas:

| File | When to load |
|------|-------------|
| `ai_docs/build.md` | Building, CMake options, Craft setup, formatting, dependencies |
| `ai_docs/architecture.md` | Code structure, sync engine, GUI layer, VFS, platform abstraction |
| `ai_docs/macos-extensions.md` | FileProvider, FinderSync, shell integration on macOS |
| `ai_docs/testing.md` | Running tests, adding new tests |
| `ai_docs/qt-patterns.md` | Qt conventions, QML modules, export macros, async patterns |

## Reference Documentation

- **Build system details**: WARP.md
- **Packaging for distributions**: PACKAGING.md
- **macOS Finder behavior and limits**: ai_docs/macos-finder-features.md
- **Current validation**: ai_docs/testing.md
- **Changelog**: CHANGELOG.md
