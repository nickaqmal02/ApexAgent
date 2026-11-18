#!/bin/zsh
# Runs the unit tests. This Mac has the Command Line Tools but not Xcode, so SwiftPM
# needs to be pointed at the Testing framework and its interop library.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
