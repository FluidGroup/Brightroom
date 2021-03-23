
#include <metal_stdlib>
using namespace metal;

#include <CoreImage/CoreImage.h> // includes CIKernelMetalLib.h

extern "C" {
  namespace coreimage {
    
    float4 colorLookup(
                       sampler inputImage,
                       sampler inputLUT,
                       float intensity
                       ) {
      
      float4 textureColor = sample(inputImage, samplerCoord(inputImage));

      return textureColor.grba;
    }
    
  }
}
