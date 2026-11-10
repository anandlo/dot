#!/usr/bin/env bash
#
# Prints "locked" when the screen is locked, "unlocked" otherwise.
#
set -euo pipefail

exec /usr/bin/python3 - <<'PY'
import ctypes
import ctypes.util

core_graphics = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
core_graphics.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
core_graphics.CFGetTypeID.restype = ctypes.c_void_p
core_graphics.CFBooleanGetValue.restype = ctypes.c_bool
core_graphics.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
core_graphics.CFStringCreateWithCString.restype = ctypes.c_void_p
core_graphics.CFStringGetCString.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool
]
core_graphics.CFStringGetCString.restype = ctypes.c_int
core_graphics.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
core_graphics.CFDictionaryGetValue.restype = ctypes.c_void_p
core_graphics.CFRelease.argtypes = [ctypes.c_void_p]

pointer = core_graphics.CGSessionCopyCurrentDictionary()
if not pointer:
    print("unknown")
    raise SystemExit(0)

key = b"CGSSessionScreenIsLocked"
string = core_graphics.CFStringCreateWithCString(None, key, len(key), False)
value_pointer = core_graphics.CFDictionaryGetValue(pointer, string)
locked = False
if value_pointer:
    # The value is a CFBoolean.
    locked = core_graphics.CFBooleanGetValue(value_pointer)
print("locked" if locked else "unlocked")
PY
