import Foundation
import Runestone
import TreeSitterBashRunestone
import TreeSitterCPPRunestone
import TreeSitterCRunestone
import TreeSitterCSSRunestone
import TreeSitterCSharpRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJSONRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterLuaRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// VS Code language ids, display names and tree-sitter grammars by file name.
enum Language {
    private static let byExt: [String: String] = [
        "rs": "rust", "py": "python", "pyw": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascriptreact", "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "json": "json", "jsonc": "jsonc", "html": "html", "htm": "html", "css": "css", "go": "go",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "cs": "csharp",
        "swift": "swift", "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript", "yml": "yaml", "yaml": "yaml",
        "toml": "toml", "md": "markdown", "markdown": "markdown", "java": "java", "rb": "ruby", "sql": "sql",
        "php": "php", "lua": "lua", "ps1": "powershell", "psm1": "powershell", "bat": "bat", "cmd": "bat",
        "txt": "plaintext", "xml": "xml", "kt": "kotlin", "dart": "dart", "vue": "vue", "svelte": "svelte",
    ]
    private static let byName: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", ".zshrc": "shellscript", ".bashrc": "shellscript",
        ".bash_profile": "shellscript", ".profile": "shellscript", "cargo.lock": "toml", ".gitignore": "ignore",
    ]
    private static let names: [String: String] = [
        "rust": "Rust", "python": "Python", "javascript": "JavaScript", "javascriptreact": "JavaScript JSX",
        "typescript": "TypeScript", "typescriptreact": "TypeScript JSX", "json": "JSON", "jsonc": "JSON with Comments",
        "html": "HTML", "css": "CSS", "go": "Go", "c": "C", "cpp": "C++", "csharp": "C#", "swift": "Swift",
        "shellscript": "Shell Script", "yaml": "YAML", "toml": "TOML", "markdown": "Markdown", "java": "Java",
        "ruby": "Ruby", "sql": "SQL", "php": "PHP", "lua": "Lua", "powershell": "PowerShell", "bat": "Batch",
        "plaintext": "Plain Text", "xml": "XML", "dockerfile": "Docker", "makefile": "Makefile", "ignore": "Ignore",
        "kotlin": "Kotlin", "dart": "Dart", "vue": "Vue", "svelte": "Svelte",
    ]

    static func id(for fileName: String) -> String? {
        let lower = (fileName as NSString).lastPathComponent.lowercased()
        if let id = byName[lower] { return id }
        let ext = (lower as NSString).pathExtension
        return ext.isEmpty ? nil : byExt[ext]
    }

    static func displayName(for fileName: String) -> String {
        id(for: fileName).flatMap { names[$0] } ?? "Plain Text"
    }

    static func treeSitter(for fileName: String) -> TreeSitterLanguage? {
        switch id(for: fileName) {
        case "rust": .rust
        case "python": .python
        case "javascript", "javascriptreact": .javaScript
        case "typescript": .typeScript
        case "typescriptreact": .tsx
        case "json", "jsonc": .json
        case "html", "xml", "vue", "svelte": .html
        case "css": .css
        case "go": .go
        case "c": .c
        case "cpp": .cpp
        case "csharp": .cSharp
        case "swift": .swift
        case "shellscript", "dockerfile", "makefile": .bash
        case "yaml": .yaml
        case "toml": .toml
        case "markdown": .markdown
        case "java", "kotlin", "dart": .java
        case "ruby": .ruby
        case "sql": .sql
        case "php": .php
        case "lua": .lua
        default: nil
        }
    }
}
