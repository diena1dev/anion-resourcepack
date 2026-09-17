#version 330

//==========================================================================//
// galaxy.glsl
//
// The milky-way sky that started life inline in position_tex_color.fsh, pulled
// out so the End sky, a preview shell and a window can all share one copy.
//
//   vec3 galaxy(vec3 dir, float time, vec2 streakUV)
//
// `dir` need not be normalised. `time` is in seconds - GameTime * 1200.0.
// `streakUV` is the screen coordinate the shooting stars run in; pass
// (2.0 * gl_FragCoord.xy - ScreenSize) / ScreenSize.y for the original look, or
// vec2(1e6) to keep them off screen and effectively disabled.
//
// The streak coordinate is a parameter rather than read from Globals so this
// file has no uniform dependencies at all, which is what lets it be pasted into
// a startup-critical shader.
//
//
// USING IT
//
//     #moj_import <anion:galaxy.glsl>
//
// works in core/item and core/sky. It does NOT work in core/position_tex_color:
// that shader also backs GUI_TEXTURED_SNIPPET, which pipeline/mojang_logo uses,
// so it is compiled before resource packs exist and #moj_import is unavailable
// to it. For that one, paste everything between the PASTE markers below - every
// symbol is gal_-prefixed precisely so it can sit alongside that file's existing
// hash / noise / fbm / rand without colliding.
//==========================================================================//

// ---------------------------- PASTE BEGIN --------------------------------

#ifndef GAL_TILT
#define GAL_TILT 2.7                                 // galactic plane angle, radians
#endif
#ifndef GAL_DUST
#define GAL_DUST 0.15                                // how dark the dust lanes are
#endif
#ifndef GAL_GLOW
#define GAL_GLOW 0.4                                 // core brightness
#endif

#ifndef GAL_SKY
#define GAL_SKY vec3(0.01, 0.02, 0.05)               // empty sky
#endif
#ifndef GAL_C1
#define GAL_C1 vec3(0.1, 0.2, 0.4)                   // band edges
#endif
#ifndef GAL_C2
#define GAL_C2 vec3(0.3, 0.4, 0.5)                   // band body
#endif
#ifndef GAL_C3
#define GAL_C3 vec3(0.3, 0.4, 0.5)                   // core
#endif

#ifndef GAL_STAR_DENSITY
#define GAL_STAR_DENSITY 90.0                        // lattice cells per unit direction
#endif
#ifndef GAL_STAR_PROB
#define GAL_STAR_PROB 0.95                           // higher = fewer bright stars
#endif
#ifndef GAL_STREAKS
#define GAL_STREAKS 2                                // shooting stars tracked at once
#endif

#ifndef GAL_PI
#define GAL_PI 3.1415926535897932384626433832795
#endif

//--------------------------------------------------------------------------//
// Noise. gal_-prefixed so this block can be pasted into a shader that already
// defines hash / noise / fbm / rand under those bare names.
//--------------------------------------------------------------------------//

// Dave Hoskins' hash33. Pure multiplies and fract: the obvious
// fract(sin(dot(...)) * bigNumber) form runs sin on the special function unit
// at roughly quarter rate, and the noise below calls this eight times per
// sample. It also distributes better once the input coordinates get large,
// where the sin version visibly bands.
vec3 gal_hash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return -1.0 + 2.0 * fract((p.xxy + p.yxx) * p.zyx);
}

// Gradient noise in 3D. Fed a normalised direction times a density it covers
// the sphere with no seam, unlike a 2D lookup on longitude/latitude.
float gal_noise(in vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(dot(gal_hash(i + vec3(0.0, 0.0, 0.0)), f - vec3(0.0, 0.0, 0.0)),
                       dot(gal_hash(i + vec3(1.0, 0.0, 0.0)), f - vec3(1.0, 0.0, 0.0)), u.x),
                   mix(dot(gal_hash(i + vec3(0.0, 1.0, 0.0)), f - vec3(0.0, 1.0, 0.0)),
                       dot(gal_hash(i + vec3(1.0, 1.0, 0.0)), f - vec3(1.0, 1.0, 0.0)), u.x), u.y),
               mix(mix(dot(gal_hash(i + vec3(0.0, 0.0, 1.0)), f - vec3(0.0, 0.0, 1.0)),
                       dot(gal_hash(i + vec3(1.0, 0.0, 1.0)), f - vec3(1.0, 0.0, 1.0)), u.x),
                   mix(dot(gal_hash(i + vec3(0.0, 1.0, 1.0)), f - vec3(0.0, 1.0, 1.0)),
                       dot(gal_hash(i + vec3(1.0, 1.0, 1.0)), f - vec3(1.0, 1.0, 1.0)), u.x), u.y), u.z);
}

float gal_fbm(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 8.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * gal_noise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

float gal_rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 gal_randColor(vec2 seed) {
    return vec3(gal_rand(seed + 13.1), gal_rand(seed + 37.7), gal_rand(seed + 91.3));
}

float gal_rand3(vec3 co) {
    return fract(sin(dot(co, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

vec3 gal_randColor3(vec3 seed) {
    return vec3(gal_rand3(seed + 13.1), gal_rand3(seed + 37.7), gal_rand3(seed + 91.3));
}

// Shooting star. Deliberately screen-space: these are transient things crossing
// your view, not fixed points on the sky.
vec3 gal_streak(float streakId, vec2 p, float time) {
    const float speed = 2.0;
    const float travelTime = 1.0 / speed;

    vec2 seed_id = vec2(streakId);
    float timeOffset = gal_rand(seed_id + 17.0) * 200.0;
    float cyclePeriod = travelTime + 0.5 + gal_rand(seed_id + 29.0) * 15.0;

    float localTime = time + timeOffset;
    float timeInCycle = mod(localTime, cyclePeriod);

    if (timeInCycle > travelTime) {
        return vec3(0.0);
    }

    float cycleID = floor(localTime / cyclePeriod);
    vec2 run_seed = vec2(streakId, cycleID);

    float a = timeInCycle / travelTime;

    float ang = gal_rand(run_seed) * 6.283;
    vec2 dir = vec2(cos(ang), sin(ang));
    vec2 offset = vec2(-dir.y, dir.x) * (gal_rand(run_seed * 9.8) * 2.0 - 1.0) * 0.8;

    vec2 center = dir * 1.4 * (a * 2.0 - 1.0) + offset;

    const float segLen = 0.2;
    float clampedProj = clamp(dot(p - center, dir), -segLen, segLen);
    float line = smoothstep(0.001, 0.0, length((p - center) - dir * clampedProj));

    float streakAlpha = line
                      * (smoothstep(0.0, 0.15, a) * smoothstep(1.0, 0.85, a))
                      * ((clampedProj + segLen) / (2.0 * segLen));

    return gal_randColor(run_seed) * streakAlpha;
}

//--------------------------------------------------------------------------//
// The sky itself.
//--------------------------------------------------------------------------//
vec3 galaxy(vec3 dir, float time, vec2 streakUV) {
    vec3 d = normalize(dir);

    // Tilt the galactic plane by rotating the direction itself, in 3D.
    // Rotating a flat uv with a mat2 instead would smear near the poles,
    // because that is not a real rotation of the sphere.
    float ca = cos(GAL_TILT);
    float sa = sin(GAL_TILT);
    vec3 g = vec3(d.x * ca - d.y * sa,
                  d.x * sa + d.y * ca,
                  d.z);

    // x runs the long way around the galactic plane, y is distance from it.
    // atan wraps at the back of the sky, but only |x| is ever used, so the
    // wrap never shows.
    vec2 rotated_uv = vec2(atan(g.z, g.x) / GAL_PI, g.y);

    // pow() compiles to exp2(y * log2(x)) - two special-function-unit ops. For
    // small integer exponents repeated multiplies are cheaper and exact, and
    // these run for every pixel.
    float bandFalloff = 1.0 - abs(rotated_uv.y);
    float bandShape = bandFalloff * bandFalloff * bandFalloff * 0.2;

    float coreGlow = 1.0 - smoothstep(0.0, 1.0, length(rotated_uv * vec2(0.5, 1.0)));
    float cg2 = coreGlow * coreGlow;
    coreGlow = cg2 * cg2 * coreGlow * GAL_GLOW;

    float milkyWay = bandShape + coreGlow;

    // Everything in this block only modulates bandShape, which falls off as the
    // cube of the distance from the galactic plane. Past |g.y| = 0.72 the whole
    // block contributes less than 1/255, so skip it - that is 28% of the
    // sphere's solid angle for free, since the measure of a sphere is uniform
    // in y and the threshold IS the fraction.
    if (abs(g.y) < 0.72) {
        // 4 octaves, not 5: gas_uv is g * 12 and gal_fbm starts at frequency 8
        // doubling per octave, so octave 5 lands at 12 * 8 * 16 = 1536 cycles
        // around the sphere - far under one pixel, contributing shimmer rather
        // than detail.
        vec3 gas_uv = g * 12.0 + vec3(123.45, 678.9, 345.67);
        float gasFBM = (gal_fbm(gas_uv, 4) + 1.0) * 0.5;
        milkyWay += gasFBM * bandShape * 0.5;

        vec3 dust_uv = g * 6.0 + vec3(456.7, 890.12, 234.56);

        // 2 octaves each: this is a domain warp whose result is scaled by 0.3
        // and added to a coordinate, so only its low frequencies displace
        // anything visible.
        vec3 dust_distort = vec3(gal_fbm(dust_uv + 15.5, 2),
                                 gal_fbm(dust_uv + 33.3, 2),
                                 gal_fbm(dust_uv + 51.1, 2)) * 0.3;

        float dustFBM = (gal_fbm(dust_uv + dust_distort, 5) + 1.0) * 0.5;
        float dustMask = smoothstep(0.45, 0.7, dustFBM);

        milkyWay *= (1.0 - dustMask * GAL_DUST);
    }

    milkyWay = max(0.0, milkyWay);

    vec3 base = mix(GAL_C1, GAL_C2, smoothstep(0.0, 0.1, milkyWay));
    base = mix(base, GAL_C3, smoothstep(0.3, 0.9, milkyWay));
    vec3 col = mix(GAL_SKY, base, milkyWay);

    // Grid-based twinkling stars, cut out of direction space so they stay
    // pinned to the sky rather than to the screen.
    vec3 starCell = floor(d * GAL_STAR_DENSITY);
    float starValue = gal_rand3(starCell);

    if (starValue > GAL_STAR_PROB) {
        vec3 cellLocal = fract(d * GAL_STAR_DENSITY) - 0.5;
        float twinkleSpeed = 1.0 + gal_rand3(starCell + 42.0) * 4.0;
        float phaseOffset = (starValue - GAL_STAR_PROB) / (1.0 - GAL_STAR_PROB) * GAL_PI * 2.0;
        float tw = 0.9 + 0.2 * sin(time * twinkleSpeed + phaseOffset);

        float b = max(0.0, 1.0 - length(cellLocal) * 2.0);
        float b2 = b * b;
        float b4 = b2 * b2;
        b = b4 * b4 * tw * tw;

        vec3 starTint = mix(vec3(2.0), gal_randColor3(starCell), gal_rand3(starCell + 123.4) * 0.7);
        col += b * starTint;
    } else {
        // A second, much finer lattice in place of the original's per-pixel
        // salt-and-pepper pass, which only worked in screen space.
        vec3 fineCell = floor(d * GAL_STAR_DENSITY * 6.0);
        float fineValue = gal_rand3(fineCell);

        if (fineValue > 0.996) {
            vec3 fineLocal = fract(d * GAL_STAR_DENSITY * 6.0) - 0.5;
            float r = gal_rand3(fineCell + 7.0);
            float b = max(0.0, 1.0 - length(fineLocal) * 2.0);
            float fb2 = b * b;
            b = fb2 * fb2 * fb2 * r * (0.25 * sin(time * (r * 5.0) + 720.0 * r) + 0.75);

            vec3 starTint = mix(vec3(1.0), gal_randColor3(fineCell), gal_rand3(fineCell + 3.3) * 0.8);
            col += b * starTint;
        }
    }

    for (int i = 0; i < GAL_STREAKS; i++) {
        col += gal_streak(float(i), streakUV, time);
    }

    return col;
}

// ----------------------------- PASTE END ---------------------------------
