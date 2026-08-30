#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:globals.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

//==========================================================================//
// these are the values we get by importing globals.glsl.
//
// layout(std140) uniform Globals {
//     ivec3 CameraBlockPos; // can be very powerful, is the literal position of the camera in a world.
//                           // where it is *less* useful is being an integer vec, which means it snaps to whole numbers.
//     vec3 CameraOffset;    // This is the fractional part of CameraBlockPos. (CameraBlockPos-CameraOffset gives precise location!!!)
//     vec2 ScreenSize;      // The window pixel dimensions of the game.
//     float GlintAlpha;
//     float GameTime;       // Counts up from 0-1 across 24000 ticks (one minecraft day). Multiply by 24000 to get ticks!
//     int MenuBlurRadius;
//     int UseRgss;
// };
//==========================================================================//

// this is our corrected position vector from our vertex shader.
in vec3 Pos;

out vec4 fragColor;

// TODO: seperate helper functions into an include file when possible.
void main() {

    // this gets us a color based on the distance from the center of the world.
    // if we export Position from sky.vsh we can get a position map of the entire skybox!
    //vec3 color = normalize(vec3(CameraBlockPos.x, CameraBlockPos.y, CameraBlockPos.z));
    
    // this is an example of how we can read FogColor (available through fog.glsl) to set the sky color!
    // fragColor = FogColor;

    // daytime detection- might break with custom sky colors!
    float dayFactor = max(max(ColorModulator.r, ColorModulator.g), ColorModulator.b);

    vec3 night = 0.5 + 0.5 * normalize(Pos);
    vec3 day   = ColorModulator.rgb;

    fragColor = vec4(mix(night, day, dayFactor), 1.0);

}
