// ok-write-probe-swap.swift — atomically swap two paths with
// renamex_np(RENAME_SWAP), the conditional update VoiceType uses to write
// into an OpenKnowledge vault. Helper of ok-write-probe.sh (Task 0 gate).
//
// Usage: ok-write-probe-swap <a> <b>   → exit 0 on swap, 1 on failure
import Darwin

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: ok-write-probe-swap <a> <b>\n", stderr)
    exit(1)
}
if renamex_np(args[1], args[2], UInt32(RENAME_SWAP)) != 0 {
    perror("renamex_np(RENAME_SWAP)")
    exit(1)
}
exit(0)
