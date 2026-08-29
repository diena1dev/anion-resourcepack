#version 330

#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

in vec3 Position;

out vec3 viewDir;

// SkyRenderer.buildSkyDisc gives us a 10 vertex TRIANGLE_FAN: a centre at
// (0, y, 0) and 9 rim vertices at radius 512, all at the same height, with
// y = +16 for the sky disc and y = -16 for the dark disc.
//
// Two problems with using that shape as-is:
//   - it only spans elevations past atan(16 / 512) = 1.79 degrees, so a band
//     around the horizon has no geometry at all and shows the clear colour
//   - the dark disc is only drawn below the horizon height (see
//     SkyRenderer.shouldRenderDarkDisc), so above y=63 nothing covers the
//     lower half of the sky
//
// So reshape the fan into a deep cone instead: centre pushed to the zenith,
// rim ring pulled in and dropped far below the camera. The fan then covers
// everything from straight up down to -89 degrees on its own. Each triangle
// stays planar, so the interpolated direction is still exact per pixel.
const float APEX_DIST = 500.0;   // fan centre, kept inside the 512 far plane
const float RING_DROP = 456.0;   // how far below the camera the rim sits
const float RING_SCALE = 0.015625; // 512 -> 8, the rim ring radius

void main() {
    float side = sign(Position.y); // +1 sky disc, -1 dark disc

    vec3 p;
    if (length(Position.xz) < 1.0) {
        p = vec3(0.0, side * APEX_DIST, 0.0);
    } else {
        p = vec3(Position.x * RING_SCALE, side * -RING_DROP, Position.z * RING_SCALE);
    }

    // The sky has to stay centred on the camera, so keep the rotation but drop
    // the translation - renderDarkDisc offsets its draw by (0, 12, 0).
    mat4 modelView = ModelViewMat;
    modelView[3].xyz = vec3(0.0);

    gl_Position = ProjMat * modelView * vec4(p, 1.0);
    viewDir = p;
}
