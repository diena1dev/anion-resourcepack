#version 330

// Can't moj_import in things used during startup, when resource packs don't exist.
// This is a copy of dynamicimports.glsl
// this shader gets loaded *really* early. (it draws the mojang logo on the loading screen!)
layout(std140) uniform DynamicTransforms {
    mat4 ModelViewMat;
    vec4 ColorModulator;
    vec3 ModelOffset;
    mat4 TextureMat;
};

layout(std140) uniform Projection {
    mat4 ProjMat;
};

// this is our entrypoint for selecting custom shaders.
// we can read the vec4 of FogColor and switch shaders from that value!
layout(std140) uniform Fog {
    vec4 FogColor;
    float FogEnvironmentalStart;
    float FogEnvironmentalEnd;
    float FogRenderDistanceStart;
    float FogRenderDistanceEnd;
    float FogSkyEnd;
    float FogCloudsEnd;
};

layout(std140) uniform Globals {
    ivec3 CameraBlockPos;
    vec3 CameraOffset;
    vec2 ScreenSize;
    float GlintAlpha;
    float GameTime;
    int MenuBlurRadius;
    int UseRgss;
};

uniform sampler2D Sampler0;

in vec3 Pos;
in vec2 texCoord0;
in vec4 vertexColor;

out vec4 fragColor;

void main() {

    // vanilla code start
    vec4 color = texture(Sampler0, texCoord0) * vertexColor;

    // this allows transparent ui elements to actually be transparent.
    // if this check is removed, black boxes are drawn over transparent sections!
    if (color.a == 0.0) {
        discard;
    }
    
    fragColor = color * ColorModulator;
    // vanilla code end

    // this check isolates the end skybox from the rest of position_tex_color's targets.
    // ProjMat checks what projection mode the verticies are being drawn in,
    // while the color check ensures that we only target the end skybox (not the block or flame overlays).
    // the *reason* we check both is to prevent any gui color that matches
    // the end sky grey from getting the end sky shader override applied to it.
    if (

        ProjMat[3][3] == 0. &&
        all(lessThan(abs(vertexColor.rgb - vec3(40.0/255.0)), vec3(0.01)))
    
    ) {

        // left in for demonstration purposes
        // and this is a normalized color derived from our vector positions!
        fragColor.rgb = 0.5 + 0.5 * normalize(Pos);

        // this is an example of how biome FogColor can be read from the position_tex_color shader.
        // fragColor = FogColor;
    
    }

}
