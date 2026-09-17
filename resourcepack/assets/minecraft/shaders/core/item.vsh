#version 330

#moj_import <minecraft:light.glsl>
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <minecraft:sample_lightmap.glsl>
#moj_import <anion:spherify.glsl>

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in ivec2 UV1;
in ivec2 UV2;
in vec3 Normal;

uniform sampler2D Sampler0;
uniform sampler2D Sampler1;
uniform sampler2D Sampler2;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;
out vec4 lightMapColor;
out vec4 overlayColor;

out vec2 texCoord0;

//==========================================================================//
// anion additions.
//
// Everything below the vanilla block is extra data the window and skybox paths
// in item.fsh need. None of it changes what vanilla items look like.
//==========================================================================//

// Camera-relative world position, after any geometry mutation. This is the same
// vector vanilla feeds into fog_spherical_distance(), which is just length(),
// so it has to be in world axes with the camera at the origin. The camera
// rotation lives in ModelViewMat and never touches it.
out vec3 posRel;

// World-space normal. Same argument: minecraft_mix_light() dots this against
// Light0_Direction / Light1_Direction, and for the level those are the raw
// constants normalize(0.2, 1.0, -0.7) and normalize(-0.2, 1.0, 0.7) with no
// matrix applied. Camera-independent shading only works if Normal is in world
// axes, and the entity's pose is baked into the vertex data CPU-side.
out vec3 winNormal;

// The untouched face tint. Vanilla folds Color into the diffuse lighting before
// it reaches the fragment shader, which destroys it as a data channel, so pass
// a clean copy through as well. For the window and skybox items this carries
// the dye colour straight from the minecraft:dyed_color component.
out vec4 rawColor;

// 1.0 when this draw uses a perspective projection, 0.0 for the orthographic
// pass that renders inventory icons. ProjMat[3][3] is 0 for perspective and 1
// for ortho. Tested here rather than in the fragment shader so the fragment
// side never has to touch the Projection block.
out float isWorld;

// Blue-channel signature of the skybox shell texture (0x55). The shell is the
// only thing that gets its vertices moved, so the test has to happen here.
//
// This is a vertex texture fetch, which GL 3.3 guarantees (at least 16 vertex
// texture image units) and which costs nothing measurable at item vertex
// counts. It is gated on the perspective test so inventory icons skip it.
// Two shells, told apart by their texture's blue channel: one drawn behind the
// world, one in front of it. 42 / 85 / 170 leaves gaps of 0.169 and 0.333
// against a tolerance of 0.02, so no amount of mip filtering confuses them.
#define SPHERE_MAGIC       (85.0 / 255.0)   // sky_sphere      - behind the world
#define SPHERE_OVER_MAGIC  (42.0 / 255.0)   // sky_sphere_over - in front of it
#define SPHERE_TOL   0.02

void main() {
    
    vec3 pos = Position;

    // Signature test. This one MUST be as strict as the fragment shader's,
    // because getting it wrong here corrupts geometry rather than colour: a
    // false positive drags that vertex onto the unit sphere, which stretches
    // its quad across the screen or collapses the face entirely.
    //
    // Testing blue alone - which is what this did - matches 8.2% of all texels
    // across 1383 of the 2065 vanilla block and item textures, so most dropped
    // and held blocks had corners flung across the sky. Requiring near-zero red
    // and green and full alpha as well brings that to zero texels across the
    // whole vanilla set.
    vec4 sig = ProjMat[3][3] == 0.0 ? textureLod(Sampler0, UV0, 0.0) : vec4(-1.0);
    bool sigShape = sig.a > 0.99 && sig.r < 0.06 && sig.g < 0.06;

    bool shellBehind = sigShape && abs(sig.b - SPHERE_MAGIC) < SPHERE_TOL;
    bool shellOver   = sigShape && abs(sig.b - SPHERE_OVER_MAGIC) < SPHERE_TOL;
    bool isShell     = shellBehind || shellOver;

    if (isShell) {
    
        // The shell is a closed cube covering every direction around the
        // entity; all that matters is which directions it spans, so reduce each
        // vertex to its direction and draw it at infinity. See skybox_clip in
        // spherify.glsl for why a finite radius cannot be made bob-proof.
        // length(Position) is the distance to the shell's own surface in this
        // direction, so the bubble wall lands exactly on the model - and tracks
        // the display entity's scale with no knob to keep in sync. Note the
        // model is a cube, so the cleared volume is cube-shaped too: 12 blocks
        // of headroom at a face centre and 20.8 at a corner, at scale 24.
        pos = normalize(Position);
        gl_Position = shellOver
            ? skybox_clip_at(pos, length(Position), ModelViewMat, ProjMat)
            : skybox_clip(pos, ModelViewMat, ProjMat);
    
    } else {

        gl_Position = ProjMat * ModelViewMat * vec4(pos, 1.0);
    
    }

    sphericalVertexDistance = fog_spherical_distance(pos);
    cylindricalVertexDistance = fog_cylindrical_distance(pos);

    vertexColor = minecraft_mix_light(Light0_Direction, Light1_Direction, Normal, Color);
    lightMapColor = sample_lightmap(Sampler2, UV2);
    overlayColor = texelFetch(Sampler1, UV1, 0);

    texCoord0 = UV0;

    // anion
    posRel = pos;
    winNormal = Normal;
    rawColor = Color;
    isWorld = ProjMat[3][3] == 0.0 ? 1.0 : 0.0;

}
