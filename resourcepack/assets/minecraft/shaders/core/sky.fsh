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
//     vec3 CameraOffset;    // TO-DOCUMENT
//     vec2 ScreenSize;      // The window pixel dimensions of the game.
//     float GlintAlpha;
//     float GameTime;       // TO-DOCUMENT (it counts up weird)
//     int MenuBlurRadius;
//     int UseRgss;
// };
//==========================================================================//

// this is our corrected position vector from our vertex shader.
in vec3 Pos;

out vec4 fragColor;

// TODO: reliably detect day/night cycles in worlds that must be day/night aware.
void main() {

    // this gets us a color based on the distance from the center of the world.
    // if we export Position from sky.vsh we can get a position map of the entire skybox!
    //vec3 color = normalize(vec3(CameraBlockPos.x, CameraBlockPos.y, CameraBlockPos.z));
    
    fragColor.xyz = 0.5 + 0.5 * normalize(Pos);;

    // this is an example of how we can read FogColor (available through fog.glsl) to set the sky color!
    // fragColor = FogColor;

}
