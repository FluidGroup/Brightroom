
#import "Cube.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Accelerate/Accelerate.h>

@implementation Cube

+ (nullable NSData *) colorCubeDataFromLUT:(nonnull UIImage *)image
{

  static const int kDimension = 64;
  
  if (!image) return nil;
  
  NSInteger width = CGImageGetWidth(image.CGImage);
  NSInteger height = CGImageGetHeight(image.CGImage);
  NSInteger rowNum = height / kDimension;
  NSInteger columnNum = width / kDimension;
  
  if ((width % kDimension != 0) || (height % kDimension != 0) || (rowNum * columnNum != kDimension)) {
    return nil;
  }
  
  float *bitmap = [self createRGBABitmapFromImage:image.CGImage];
  if (bitmap == NULL) return nil;
  
  // Convert bitmap data written in row,column order to cube data written in x:r, y:g, z:b representation where z varies > y varies > x.
  NSInteger size = kDimension * kDimension * kDimension * sizeof(float) * 4;
  float *data = malloc(size);
  int bitmapOffset = 0;
  int z = 0;
  for (int row = 0; row <  rowNum; row++)
  {
    for (int y = 0; y < kDimension; y++)
    {
      int tmp = z;
      for (int col = 0; col < columnNum; col++) {
        NSInteger dataOffset = (z * kDimension * kDimension + y * kDimension) * 4;
        
        const float divider = 255.0;
        vDSP_vsdiv(&bitmap[bitmapOffset], 1, &divider, &data[dataOffset], 1, kDimension * 4); // Vector scalar divide; single precision. Divides bitmap values by 255.0 and puts them in data, processes each column (kDimension * 4 values) at once.
        
        bitmapOffset += kDimension * 4; // shift bitmap offset to the next set of values, each values vector has (kDimension * 4) values.
        z++;
      }
      z = tmp;
    }
    z += columnNum;
  }
  
  free(bitmap);
  
  return [NSData dataWithBytesNoCopy:data length:size freeWhenDone:YES];
}

+ (float *)createRGBABitmapFromImage:(CGImageRef)image {
  CGContextRef context = NULL;
  CGColorSpaceRef colorSpace;
  unsigned char *bitmap;
  NSInteger bitmapSize;
  NSInteger bytesPerRow;
  
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  
  bytesPerRow   = (width * 4);
  bitmapSize     = (bytesPerRow * height);
  
  bitmap = malloc( bitmapSize );
  if (bitmap == NULL) return NULL;
  
  colorSpace = CGColorSpaceCreateDeviceRGB();
  if (colorSpace == NULL) {
    free(bitmap);
    return NULL;
  }
  
  context = CGBitmapContextCreate(bitmap,
                                  width,
                                  height,
                                  8,
                                  bytesPerRow,
                                  colorSpace,
                                  (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  
  if (context == NULL) {
    free (bitmap);
    return NULL;
  }
  
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGContextRelease(context);
  
  float *convertedBitmap = malloc(bitmapSize * sizeof(float));
  vDSP_vfltu8(bitmap, 1, convertedBitmap, 1, bitmapSize); // Converts an array of unsigned 8-bit integers to single-precision floating-point values.
  free(bitmap);
  
  return convertedBitmap;
}

@end
