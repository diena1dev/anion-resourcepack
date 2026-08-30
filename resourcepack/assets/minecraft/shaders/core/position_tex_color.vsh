#version 330

// Can't moj_import in things used during startup, when resource packs don't exist.
// This is a copy of dynamicimports.glsl and projection.glsl
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

in vec3 Position;
in vec2 UV0;
in vec4 Color;

out vec3 Pos;
out vec2 texCoord0;
out vec4 vertexColor;

void main() {
    
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    Pos = Position;
    texCoord0 = UV0;
    vertexColor = Color;

}
