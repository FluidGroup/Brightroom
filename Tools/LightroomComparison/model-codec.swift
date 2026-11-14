// Compress generated calibration data using the same Foundation codec as the library.
import Foundation

precondition(CommandLine.arguments.count == 4, "usage: model-codec compress|decompress input output")
let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) as NSData
let output: NSData
switch CommandLine.arguments[1] {
case "compress": output = try input.compressed(using: .lzfse)
case "decompress": output = try input.decompressed(using: .lzfse)
default: preconditionFailure("Unknown operation")
}
try (output as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
