// A tiny utility that presses a key combination for the end-to-end test.
//
//     swiftc -O scripts/press-key.swift -o /tmp/press-key
//     /tmp/press-key 2 option command
//     /tmp/press-key 2 option command --hold 3
//
// The key code is a Carbon virtual key code (`kVK_*`): 2 is `D`, 9 is `V`,
// 37 is the ANSI J. The modifiers are `command`, `option`, `control` and
// `shift`.
//
// Dot is push-to-talk: the recording lasts as long as the key is held. The
// `--hold` option keeps the key down for that many seconds, which is how the
// test drives the app.

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
var keyCode: UInt16?
var flags = CGEventFlags()
var hold: Double = 0
var index = 0

while index < arguments.count {
    let argument = arguments[index]
    switch argument.lowercased() {
    case "--hold":
        guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) else {
            FileHandle.standardError.write(Data("usage: press-key <key-code> [modifiers] [--hold seconds]\n".utf8))
            exit(2)
        }
        hold = seconds
        index += 2
        continue
    case "command", "cmd":
        flags.insert(.maskCommand)
    case "option", "alt":
        flags.insert(.maskAlternate)
    case "control", "ctrl":
        flags.insert(.maskControl)
    case "shift":
        flags.insert(.maskShift)
    default:
        if keyCode == nil, let code = UInt16(argument) {
            keyCode = code
        } else {
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            exit(2)
        }
    }
    index += 1
}

guard let code = keyCode else {
    FileHandle.standardError.write(Data("usage: press-key <key-code> [command] [option] [control] [shift] [--hold seconds]\n".utf8))
    exit(2)
}

guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
else {
    FileHandle.standardError.write(Data("could not build the key event\n".utf8))
    exit(1)
}

down.flags = flags
up.flags = flags
down.post(tap: .cghidEventTap)
if hold > 0 {
    Thread.sleep(forTimeInterval: hold)
}
up.post(tap: .cghidEventTap)
print("pressed \(code) with \(flags.rawValue) for \(hold) seconds")
