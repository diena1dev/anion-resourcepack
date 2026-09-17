#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:globals.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <anion:slipspace.glsl>
#moj_import <anion:galaxy.glsl>

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec4 lightMapColor;
in vec4 overlayColor;
in vec2 texCoord0;

// anion additions, see item.vsh
in vec3 posRel;
in vec3 winNormal;
in vec4 rawColor;
in float isWorld;

out vec4 fragColor;

//==========================================================================//
// CONFIG
//==========================================================================//

// Side length of window_ramp.png in texels. The ramp encodes the window's own
// local coordinates: R = 0..1 left to right, G = 0..1 bottom to top. Knowing
// the sprite's pixel size lets us undo the texel quantisation exactly, so 64 is
// plenty - it does not limit precision.
#define RAMP_PX 64.0

// Blue-channel signatures. Minecraft builds atlas mipmaps per sprite, so the
// interior of a sprite keeps its value at every mip level; the tolerances cover
// the outer texel ring and driver rounding. The two magics are far enough apart
// that no plausible filtering confuses them.
#define WINDOW_MAGIC      (170.0 / 255.0)   // window_ramp.png,     flat aperture
#define SPHERE_MAGIC       (85.0 / 255.0)   // sky_sphere.png,      shell behind the world
#define SPHERE_OVER_MAGIC  (42.0 / 255.0)   // sky_sphere_over.png, shell in front of it
#define MAGIC_TOL    0.02

// The window ramp spends red and green on local coordinates, so blue was its
// only signature - and blue alone matches 1.6% of vanilla item texels, which
// paints slipspace over scattered pixels of ordinary items. Alpha is unused on
// this path, so it carries a second independent constraint. 200 is far from
// both 255 and 0, the only alpha values ordinary item textures use. Together
// the two match zero texels across the whole vanilla set.
#define WINDOW_ALPHA (200.0 / 255.0)

#define MARCH_STEPS 64
#define MARCH_FAR   24.0

// Noise-domain multiplier for the flat window.
//
// Keep this at 1.0 to match the shell and the dimension sky. Anything else and
// a window pointed at the same slipspace shows it at a different scale, which
// breaks the whole premise of a window onto it.
//
// It was 5.0 for a while, on the theory that a narrow aperture would zoom into
// a single noise lattice cell and show two or three giant creases. Rendering
// the window offline at 1.0 disproved that - the fracture field is perfectly
// well formed at native scale - and the banding it was meant to fix turned out
// to be the splinter mask's threshold contour instead.
//
// Only worth raising for a genuinely tiny aperture, and only if you accept that
// it will no longer match the sky.
#define WINDOW_DETAIL 1.0

//==========================================================================//
// EFFECT 0 - FRAME DEBUG
//
// Draws the reconstructed local coordinate system directly. If this looks
// right, the ramp decode, the tangent frame and the ray transform are all
// correct and every other effect is trustworthy.
//   red   = local X, 0 at the left edge, 1 at the right
//   green = local Y, 0 at the bottom, 1 at the top
//   grid  = eighths of the window, so it stays square under any entity scale
//   dot   = window origin
//   blue  = how directly the view ray points into the window
//==========================================================================//
vec3 fxDebug(vec2 lp, vec3 rd) {
    vec3 col = vec3(lp + 0.5, 0.0);

    vec2 g = abs(fract(lp * 8.0) - 0.5);
    float grid = 1.0 - smoothstep(0.0, 0.05, min(g.x, g.y));
    col = mix(col, vec3(1.0), grid * 0.35);

    col = mix(col, vec3(1.0, 0.0, 1.0), 1.0 - smoothstep(0.02, 0.035, length(lp)));

    col.b = max(col.b, rd.z * 0.6);
    return col;
}

//==========================================================================//
// EFFECT 2 - SHAPES MARCHED FORWARD FROM THE APERTURE
//
// Everything here is defined in window-local units where the window is 1x1 and
// +z runs into the wall. Move or rotate the display entity and the whole scene
// follows it rigidly, because the frame is rebuilt from the geometry itself.
//==========================================================================//
float mapShapes(vec3 p, float t) {
    float d = p.y + 1.0;                                  // floor, one window below the sill

    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float z = 0.8 + fi * 1.5;                         // receding into the window
        float x = sin(t * 0.8 + fi * 1.1) * 0.45;
        float y = -0.55 + abs(sin(t * 1.5 + fi * 0.9)) * 0.85;
        d = min(d, length(p - vec3(x, y, z)) - 0.22);
    }

    return d;
}

vec3 fxShapes(vec3 ro, vec3 rd, vec3 tint, float t) {
    float dist = 0.0;
    bool hit = false;

    for (int i = 0; i < MARCH_STEPS; i++) {
        float d = mapShapes(ro + rd * dist, t);
        if (d < 0.002) { hit = true; break; }
        dist += d;
        if (dist > MARCH_FAR) break;
    }

    if (!hit) {
        return vec3(0.02, 0.03, 0.06) * (1.0 + max(0.0, rd.z));
    }

    vec3 p = ro + rd * dist;
    vec2 e = vec2(0.0025, 0.0);
    vec3 n = normalize(vec3(
        mapShapes(p + e.xyy, t) - mapShapes(p - e.xyy, t),
        mapShapes(p + e.yxy, t) - mapShapes(p - e.yxy, t),
        mapShapes(p + e.yyx, t) - mapShapes(p - e.yyx, t)));

    float lam = max(0.0, dot(n, normalize(vec3(0.4, 0.8, -0.45))));
    vec3 col = tint * (0.12 + 0.88 * lam);
    col += tint * 0.25 * pow(max(0.0, 1.0 - abs(dot(n, rd))), 3.0);
    col *= exp(-dist * 0.13);                             // fade with depth into the window
    return col;
}

//==========================================================================//
// EFFECT 3 - TUNNEL
//
// Analytic plane intersections instead of a march, so it stays cheap. Rings sit
// at fixed local z and slide toward the aperture over time.
//==========================================================================//
vec3 fxTunnel(vec3 ro, vec3 rd, vec3 tint, float t) {
    vec3 col = vec3(0.0);
    if (rd.z < 1e-4) return col;

    float slide = mod(t * 1.4, 0.6);

    for (int i = 0; i < 24; i++) {
        float z = float(i) * 0.6 + 0.35 - slide;
        float k = (z - ro.z) / rd.z;
        if (k < 0.0) continue;

        vec3 p = ro + rd * k;
        float rad = length(p.xy);
        float ring = smoothstep(0.03, 0.0, abs(rad - 0.42));
        float spokes = 0.65 + 0.35 * sin(atan(p.y, p.x) * 6.0 + t * 0.9 + z);
        col += tint * ring * spokes * exp(-z * 0.16) * 0.9;
    }

    return col;
}

//==========================================================================//
// DISPATCH
//
// rawColor is the untouched face tint, which for these items is the
// minecraft:dyed_color component. The red byte picks the effect, the whole
// colour tints effects 2 and 3.
//==========================================================================//
// `rd` is the aperture-local ray, `rdW` the world one. They are the same vector
// on the shell; on a flat window they differ by the window's own orientation.
//
// Slipspace takes the world ray, so a window is a true porthole: it shows the
// same patch of sky you would see looking that way, and turning the window
// reframes it instead of swinging the view. The marched effects keep the local
// ray, since their geometry is defined relative to the aperture and is meant to
// rotate with it.
// Eight slots rather than four, so more skies can be previewed side by side
// without renumbering every time one is added. The red byte picks the slot in
// steps of 32.
vec3 runEffect(vec3 ro, vec3 rd, vec3 rdW, vec2 lp, float t, float detail) {
    vec3 tint = rawColor.rgb;
    int fx = int(clamp(rawColor.r * 8.0, 0.0, 7.999));

    // Screen coordinate the galaxy's shooting stars run in, matching the
    // original inline version in position_tex_color.fsh.
    vec2 streakUV = (2.0 * gl_FragCoord.xy - ScreenSize) / ScreenSize.y;

    if (fx == 0) return fxDebug(lp, rd);
    if (fx == 1) return slipspace_detail(rdW, t, detail);   // anion:slipspace.glsl
    if (fx == 2) return galaxy(rdW, t, streakUV);           // anion:galaxy.glsl
    if (fx == 3) return fxShapes(ro, rd, tint, t);
    if (fx == 4) return fxTunnel(ro, rd, tint, t);

    return slipspace_detail(rdW, t, detail);                // 5-7 spare
}

//==========================================================================//
// MAIN
//==========================================================================//

void main() {
    vec4 color = texture(Sampler0, texCoord0);

    // GameTime counts 0..1 over a Minecraft day; a day is 24000 ticks at 20 tps,
    // so this is seconds - the same units a shadertoy iTime would be in.
    float t = GameTime * 1200.0;

    // Alpha is part of each signature now rather than a shared precondition,
    // because the shells and the window carry different values in it.
    bool perspective = isWorld > 0.5;

    //----------------------------------------------------------------------//
    // Walk-in skybox shell.
    //
    // item.vsh has already pushed every vertex onto a sphere centred on the
    // eye, so the fragment's own camera-relative position IS the view ray and
    // no frame reconstruction is needed. Tessellation of the shell is therefore
    // completely invisible here - the sky is exact however coarse the cube is.
    //----------------------------------------------------------------------//
    // Both shells shade identically - only the depth they were pinned to in
    // item.vsh differs, and that is already decided by the time we get here.
    if (perspective
     && color.a > 0.99
     && (abs(color.b - SPHERE_MAGIC) < MAGIC_TOL || abs(color.b - SPHERE_OVER_MAGIC) < MAGIC_TOL)
     && color.r < 0.06 && color.g < 0.06) {
        vec3 rd = normalize(posRel);
        fragColor = vec4(runEffect(vec3(0.0), rd, rd, rd.xy, t, 1.0) * ColorModulator.rgb, 1.0);
        return;
    }

    //----------------------------------------------------------------------//
    // Flat window.
    //----------------------------------------------------------------------//
    if (perspective
     && abs(color.a - WINDOW_ALPHA) < MAGIC_TOL
     && abs(color.b - WINDOW_MAGIC) < MAGIC_TOL) {

        // ---- 1. exact window-local coordinates ------------------------------
        //
        // The ramp is quantised to RAMP_PX texels, which would show up as
        // stair-stepping in the marched interior. texCoord0 is a smooth
        // interpolated varying though, so the sub-texel remainder recovers the
        // exact position: sample the ramp at mip 0 for the texel-centre value,
        // then add where inside that texel we actually are.
        vec4 ramp = textureLod(Sampler0, texCoord0, 0.0);

        vec2 atlasPx = vec2(textureSize(Sampler0, 0));
        vec2 sub = fract(texCoord0 * atlasPx) - 0.5;

        // G was authored flipped (texture V runs down, local Y runs up), so the
        // sub-texel correction is subtracted on that axis.
        vec2 local = vec2(ramp.r + sub.x / RAMP_PX,
                          ramp.g - sub.y / RAMP_PX);
        vec2 lp = local - 0.5;                            // centre the window

        // ---- 2. tangent frame ----------------------------------------------
        //
        // Solve dP = Tu * dUx + Bu * dUy for the world vectors matching one unit
        // of texCoord0, then rescale into window units.
        //
        // Differentiating texCoord0 rather than `local` matters. `local` is a
        // texel step plus a sawtooth, and although the two cancel in exact
        // arithmetic, a 2x2 quad that straddles the sprite's outermost texel
        // sees the step and the sawtooth disagree - measured over a 420px
        // aperture that drives d(local)/dx to -5.5x its true value on the outer
        // ring. texCoord0 is a plain interpolated varying with no wrap in it
        // anywhere, so the whole failure mode disappears.
        //
        // The rescale is exact and needs no extra data: the sprite is RAMP_PX
        // texels across, so it spans RAMP_PX/atlasPx of texture space, and that
        // ratio converts per-texCoord vectors into per-window-unit vectors. An
        // item_display at any uniform scale still works with no bookkeeping.
        vec2 spriteUV = vec2(RAMP_PX) / atlasPx;

        vec3 dPx = dFdx(posRel);
        vec3 dPy = dFdy(posRel);
        vec2 dUx = dFdx(texCoord0);
        vec2 dUy = dFdy(texCoord0);

        float det = dUx.x * dUy.y - dUy.x * dUx.y;

        if (abs(det) > 1e-18) {
            vec3 Tu = (dPx * dUy.y - dPy * dUx.y) / det;
            vec3 Bu = (dPy * dUx.x - dPx * dUy.x) / det;

            vec3 Tw =  Tu * spriteUV.x;
            vec3 Bw = -Bu * spriteUV.y;   // local Y runs opposite to texture V

            // Normal comes from the vertex attribute, flipped to face the
            // viewer so both declared faces behave. cross(Tw, Bw) would work
            // just as well and is the fallback for shaders with no Normal.
            vec3 N = normalize(winNormal);
            vec3 rdW = normalize(posRel);
            if (dot(N, rdW) > 0.0) N = -N;

            // Gram-Schmidt against N, keeping the real V direction so the back
            // face mirrors the way real geometry would.
            vec3 T = normalize(Tw - N * dot(N, Tw));
            vec3 B = Bw - N * dot(N, Bw);
            B = normalize(B - T * dot(T, B));

            // Window-local ray. +z points into the window because -N does.
            vec3 rd = normalize(vec3(dot(rdW, T), dot(rdW, B), dot(rdW, -N)));
            vec3 ro = vec3(lp, 0.0);                      // start on the aperture plane

            // No lightmap, no overlay, no fog: the interior is somewhere else.
            // Depth is deliberately left as the quad's own value - writing a
            // farther gl_FragDepth would fail the reversed-Z GEQUAL test
            // against whatever is already behind the window.
            // A window subtends a narrow cone, so the sky detail is scaled up to
            // stop it zooming into a single noise lattice cell. See the note on
            // slipspace_detail.
            fragColor = vec4(runEffect(ro, rd, rdW, lp, t, WINDOW_DETAIL) * ColorModulator.rgb, 1.0);
            return;
        }

        // Degenerate derivatives (edge-on sliver). Fall through to something
        // solid rather than dividing by zero.
        fragColor = vec4(rawColor.rgb * 0.1, 1.0);
        return;
    }

    // ---- vanilla path, untouched ----
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

    color *= vertexColor * ColorModulator;
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayColor.a);
    color *= lightMapColor;

    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}
