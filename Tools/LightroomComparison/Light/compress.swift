// Lossless packing for the frozen Float32 tonal-response resource.
import Foundation
precondition(CommandLine.arguments.count == 3, "usage: compress input.bin output.lzfse")
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
precondition(!FileManager.default.fileExists(atPath: output.path), "Do not overwrite evidence")
let data = try Data(contentsOf: input)
let packed = try (data as NSData).compressed(using: .lzfse) as Data
let restored = try (packed as NSData).decompressed(using: .lzfse) as Data
precondition(restored == data)
try packed.write(to: output)
print("\(data.count) -> \(packed.count) bytes")
