
#include <metal_stdlib>
using namespace metal;

#include <CoreImage/CoreImage.h>

extern "C" {
  namespace coreimage {
    
    float4 colorLookup(
                       sampler inputImage,
                       sampler inputLUT,
                       float intensity
                       ) {
      
      float4 textureColor = sample(inputImage, samplerCoord(inputImage));
      
      textureColor = clamp(textureColor, float4(0.0), float4(1.0));
      
      float blueColor = textureColor.b * 63.0;
      
      float2 quad1;
      quad1.y = floor(floor(blueColor) / 8.0);
      quad1.x = floor(blueColor) - (quad1.y * 8.0);
      
      float2 quad2;
      quad2.y = floor(ceil(blueColor) / 8.0);
      quad2.x = ceil(blueColor) - (quad2.y * 8.0);
      
      float2 texPos1;
      texPos1.x = (quad1.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
      texPos1.y = (quad1.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);
      
      float2 texPos2;
      texPos2.x = (quad2.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
      texPos2.y = (quad2.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);
      
      texPos1.y = 1.0 - texPos1.y;
      texPos2.y = 1.0 - texPos2.y;
      
      float4 inputLUTExtent = samplerExtent(inputLUT);
      
      float4 newColor1 = sample(inputLUT, samplerTransform(inputLUT, texPos1 * float2(512.0) + inputLUTExtent.xy));
      float4 newColor2 = sample(inputLUT, samplerTransform(inputLUT, texPos2 * float2(512.0) + inputLUTExtent.xy));
      
      float4 newColor = mix(newColor1, newColor2, fract(blueColor));
      return mix(textureColor, float4(newColor.rgb, textureColor.a), intensity);

    }
    
  }
}
