import CoreImage
import ImageIO
import Foundation
import UniformTypeIdentifiers
precondition(CommandLine.arguments.count == 3, "usage: adaptive-holdout-inputs.swift photograph output-directory")
let out=URL(fileURLWithPath: CommandLine.arguments[2],isDirectory:true)
precondition(!FileManager.default.fileExists(atPath:out.path))
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let linear=CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)!
let p3=CGColorSpace(name:CGColorSpace.displayP3)!
let context=CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf])
let input=CIImage(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))!
// Edge extension prevents Lanczos from introducing transparent boundary pixels.
let resized=input.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:0.25,"inputAspectRatio":1]).cropped(to:input.extent.applying(.init(scaleX:0.25,y:0.25)))
try context.writeTIFFRepresentation(of:resized,to:out.appendingPathComponent("photo.tiff"),format:.RGBA16,colorSpace:p3)
var pixels=[UInt16](repeating:0,count:1024*256*3)
for y in 0..<256 {for x in 0..<1024 {
 let u=Double(x)/1023;let v=Double(y)/255
 let values=[0.35+0.25*sin(2*Double.pi*u),0.45+0.25*cos(2*Double.pi*v),0.30+0.20*sin(2*Double.pi*(u+v))]
 for c in 0..<3 {pixels[(y*1024+x)*3+c]=UInt16((values[c]*65535).rounded()).littleEndian}
}}
let data=pixels.withUnsafeBytes {Data($0)}
let bitmap=CGImage(width:1024,height:256,bitsPerComponent:16,bitsPerPixel:48,bytesPerRow:1024*6,space:p3,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let writer=CGImageDestinationCreateWithURL(out.appendingPathComponent("color-scene.tiff") as CFURL,UTType.tiff.identifier as CFString,1,nil)!
CGImageDestinationAddImage(writer,bitmap,[kCGImagePropertyOrientation:1] as CFDictionary)
precondition(CGImageDestinationFinalize(writer))
