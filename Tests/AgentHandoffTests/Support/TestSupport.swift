import Foundation
import MergeCueCore
@testable import AgentHandoff

/// A unique temporary directory (resolved, so `/var` vs `/private/var` never differs in comparisons).
func makeTempDirectory(_ label: String = #function) throws -> URL {
    let safe = label.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appending(path: "AgentHandoffTests-\(safe.prefix(24))-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // `realpath` (not `resolvingSymlinksInPath`, which maps `/private/var` back to `/var`) so `pwd` output matches.
    guard let resolved = realpath(MergeCuePaths.fileSystemPath(url), nil) else { return url }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
}

/// Writes an executable `/bin/sh` script.
@discardableResult
func writeScript(_ url: URL, _ body: String) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
}

func posixPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: MergeCuePaths.fileSystemPath(url))
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func readText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Minimal environment for fake CLIs: no user PATH customisations, a temp HOME.
func testEnvironment(home: URL, extra: [String: String] = [:]) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": MergeCuePaths.fileSystemPath(home), "LANG": "C"]
    env.merge(extra) { $1 }
    return env
}

/// A fixed instant for deterministic timestamps: 2026-03-04T05:06:07Z.
let fixedNow = Date(timeIntervalSince1970: 1_772_600_767)

/// A stdio MCP server written in `sh` + `sed` (no dependencies), speaking just enough JSON-RPC for the verifier:
/// initialize, tools/list, tools/call (list_attention → `app_unavailable` error; get_task → ok), ping.
/// Every tools/call name is appended to `$CALL_LOG` when set. (Swift's encoder escapes `/` as `\/`, hence the
/// second `sed`.)
let shellMCPServer = #"""
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E -n 's/.*"id":("[^"]*"|[0-9]+).*/\1/p')
  method=$(printf '%s\n' "$line" | sed -E -n 's/.*"method":"([^"]*)".*/\1/p' | sed 's#\\/#/#g')
  [ -z "$id" ] && continue
  case "$method" in
    initialize)
      pv=$(printf '%s\n' "$line" | sed -E -n 's/.*"protocolVersion":"([^"]*)".*/\1/p')
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":{"tools":{}},"serverInfo":{"name":"mergecue","version":"9.9.9"}}}\n' "$id" "$pv";;
    tools/list)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"list_attention","inputSchema":{"type":"object"}},{"name":"get_task","inputSchema":{"type":"object"}},{"name":"claim_task","inputSchema":{"type":"object"}}]}}\n' "$id";;
    tools/call)
      tool=$(printf '%s\n' "$line" | sed -E -n 's/.*"name":"([^"]*)".*/\1/p')
      [ -n "$CALL_LOG" ] && printf '%s\n' "$tool" >> "$CALL_LOG"
      if [ "$tool" = "list_attention" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"code\\":\\"app_unavailable\\",\\"message\\":\\"MergeCue app is not running\\",\\"retryable\\":true}"}],"isError":true}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{}"}]}}\n' "$id"
      fi;;
    *)
      printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id";;
  esac
done
"""#
