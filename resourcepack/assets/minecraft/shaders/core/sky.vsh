#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

in vec3 Position;

// we can have an infinite amount of `out`s in a vertex shader.
// this is how we transfer info from the vertex pipeline to the fragment pipeline.
out vec3 Pos;

void main() {

    vec4 view = vec4(Position, 1.0);                     // used as our view, this attaches the sky plane to the camera.
    vec4 modView = vec4(view.x, view.z, view.y*-1, 1.0); // this swings/rotates the sky plane forward, in front of the camera.
    vec4 clip = ProjMat * modView;                       // and then this puts the view within the clip planes.

    // this is the nuanced part. since we rotated the sky plane forward and attached it to the camera,
    // the physical verticies are no longer a suitable reference in skybox position. fortunately,
    // we get position from an outside source, which we can multiply by our ModelViewMat (which
    // uses fancy math to fix vectors to one point by cancelling out camera pitch and roll) to get
    // the same sort of Position information we would have with the vanilla sky.vsh file.
    vec4 modPos = ModelViewMat * view;

    gl_Position = clip;   // this is where we pass our on-screen vector position.
    Pos.xyz = modPos.xyz; // this passes our corrected view through to sky.fsh.

}
