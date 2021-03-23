
#include <metal_stdlib>
using namespace metal;

#include <CoreImage/CoreImage.h> // includes CIKernelMetalLib.h

extern "C" {
  namespace coreimage {
    
    float4 colorLookup(sample_t s) {
      
      return s.grba;
    }
    
  }
}
