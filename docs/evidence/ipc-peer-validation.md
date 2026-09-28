# Evidence: IPC peer code-signature validation with the signed build

Date: 2026-09-28, macOS 26.6.2. Build: `scripts/build-app.sh Debug` → `dist/MergeCue.app`, signed with the owner's
**Apple Development** identity (team `TTSKDZ455K`), Hardened Runtime on for the app and the embedded helper.
Check: `scripts/check-ipc-peer-validation.sh` (demo data, throwaway `MERGECUE_HOME=/tmp/mcipc-XXXXXX`; the owner's
own MergeCue instance that was running from Xcode, pid 33106, was left untouched).

What the app enforces on its private socket (DECISIONS D7/D11, `RuntimeIPC`): same uid (`getpeereid`) + the
per-launch token + — because the app itself is signed with a Team ID — the code requirement
`anchor apple generic and certificate leaf[subject.OU] = "TTSKDZ455K" and identifier "com.thiagocenturion.MergeCue.mcp"`,
checked on the peer's audit token (`SecCodeCheckValidity`).

| # | Client | Signature | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | `dist/MergeCue.app/Contents/MacOS/mergecue-mcp --self-test` | Apple Development, team TTSKDZ455K, id `com.thiagocenturion.MergeCue.mcp` | accepted | **OK**, exit 0 |
| 2 | Copy of the same helper, `codesign -f -s -` | ad-hoc, no team (identifier unchanged) | rejected | **rejected** (`unauthorized`, OSStatus -67050), exit 1 |
| 3 | `.build/debug/mergecue-mcp --self-test` (SwiftPM) | linker ad-hoc, no team | rejected | **rejected** (`unauthorized`, OSStatus -67050), exit 1 |
| 4 | Bundled helper again | as #1 | accepted after rejections | **OK**, exit 0 |

After the check the launched app (and only it) received SIGTERM: it exited and removed its socket.

Note: the token file is readable by the same user, so #2 and #3 presented a valid token — the rejection comes from
the code-signature requirement alone. Unsigned/ad-hoc development builds of the **app** skip this check (uid + token
only, logged at startup); the requirement is only as strong as the signing identity (Apple Development here; a
Developer ID build would use the same team requirement).

## Transcript (paths shortened)

```
home=<home> (throwaway)
other MergeCue processes left alone: 33106 
--- signatures
Identifier=com.thiagocenturion.MergeCue
CodeDirectory v=20500 size=456 flags=0x10000(runtime) hashes=3+7 location=embedded
Authority=Apple Development: Thiago R. Centurion (A9VB7Q9R38)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TTSKDZ455K
Runtime Version=26.5.0
Identifier=com.thiagocenturion.MergeCue.mcp
CodeDirectory v=20500 size=27020 flags=0x10000(runtime) hashes=833+7 location=embedded
Authority=Apple Development: Thiago R. Centurion (A9VB7Q9R38)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TTSKDZ455K
app pid=97349 socket=srw-------@ 1 thiagocenturion  wheel  0 Sep 28 18:51 <home>/ipc/mergecue.sock
--- 1. bundled helper (Apple Development, team TTSKDZ455K, id com.thiagocenturion.MergeCue.mcp)
[mergecue-mcp] self-test: OK — mergecue-mcp 0.1.0 connected to MergeCue 0.1.0 (IPC protocol 1, demo data) at <home>/ipc/mergecue.sock.
exit=0
--- 2. ad-hoc re-signed copy of the same helper
<home>/mergecue-mcp-adhoc: replacing existing signature
Identifier=com.thiagocenturion.MergeCue.mcp
CodeDirectory v=20400 size=26841 flags=0x2(adhoc) hashes=833+2 location=embedded
Signature=adhoc
TeamIdentifier=not set
[mergecue-mcp] self-test: FAILED — [unauthorized] This process is not allowed to connect to MergeCue (code signature check failed). (socket: <home>/ipc/mergecue.sock)
exit=1
--- 3. unsigned SwiftPM build (linker ad-hoc signature)
Identifier=mergecue-mcp-55554944234cf7aaad483941a48490a50436b2e4
Signature=adhoc
TeamIdentifier=not set
[mergecue-mcp] self-test: FAILED — [unauthorized] This process is not allowed to connect to MergeCue (code signature check failed). (socket: <home>/ipc/mergecue.sock)
exit=1
--- 4. bundled helper again (the server keeps accepting the legitimate peer after rejections)
[mergecue-mcp] self-test: OK — mergecue-mcp 0.1.0 connected to MergeCue 0.1.0 (IPC protocol 1, demo data) at <home>/ipc/mergecue.sock.
exit=0
--- app log (dev.mergecue) since launch
2026-09-28 18:51:20.128 Df MergeCue[97349:12238e1] [dev.mergecue:runtime] IPC listening at <home>/ipc/mergecue.sock; peers: uid + token + anchor apple generic and certificate leaf[subject.OU] = "TTSKDZ455K" and identifier "com.thiagocenturion.MergeCue.mcp"
2026-09-28 18:51:21.820 Df MergeCue[97349:12238de] [dev.mergecue:ipc] IPC: rejected peer(uid: 501, pid: 97608): The peer's code signature does not satisfy the MergeCue requirement. (OSStatus -67050)
2026-09-28 18:51:25.522 Df MergeCue[97349:1223a97] [dev.mergecue:ipc] IPC: rejected peer(uid: 501, pid: 97641): The peer's code signature does not satisfy the MergeCue requirement. (OSStatus -67050)
--- quit (SIGTERM to pid 97349 only)
app exited
socket removed
```
