#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

// this is the only surefire way of getting a constantly updaing GameTime reference.
layout(std140) uniform Globals {
    ivec3 CameraBlockPos; // can be very powerful, is the literal position of the camera in a world.
                          // where it is *less* useful is being an integer vec, which means it snaps to whole numbers.
    vec3 CameraOffset;    // TO-DOCUMENT
    vec2 ScreenSize;      // The window pixel dimensions of the game.
    float GlintAlpha;
    float GameTime;       // TO-DOCUMENT (it counts up weird)
    int MenuBlurRadius;
    int UseRgss;
};

// this is our corrected position vector from our vertex shader.
in vec3 Pos;

out vec4 fragColor;

// TODO: reliably detect day/night cycles in worlds that must be day/night aware.
void main() {

    // this gets us a color based on the distance from the center of the world.
    // if we export Position from sky.vsh we can get a position map of the entire skybox!
    //vec3 color = 0.5 + normalize(vec3(CameraBlockPos.x, CameraBlockPos.y, CameraBlockPos.z));
    
    vec3 color = 0.5 + 0.5 * normalize(Pos);
    vec4 colorVec4 = vec4(color.x, color.y, color.z, 1.0);
    vec4 modVec4 = colorVec4;

    fragColor.xyz = color;

}
