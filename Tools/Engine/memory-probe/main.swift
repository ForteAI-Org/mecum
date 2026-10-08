//
//  main.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation

// The living memory's process helper: one store in a process of its own, driven by lines on its
// standard input, one answer per line on its standard output. `Probe.usage` lists the commands.

let probe = Probe()
while let line = readLine() {
    if await probe.perform(line) == .exit { break }
}
await probe.end()
