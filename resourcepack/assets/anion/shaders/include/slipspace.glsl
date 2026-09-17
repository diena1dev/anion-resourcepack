#version 330

//==========================================================================//
// slipspace.glsl
//
// A featureless grey-to-black void with bright fractures splintering through
// the walls at irregular intervals. Direction-driven, so the same code serves
// a flat window, a walk-in shell and a whole dimension's sky.
//
//   vec3 slipspace(vec3 dir, float time)
//
// `dir` need not be normalised. `time` is in seconds - GameTime * 1200.0,
// since GameTime counts 0..1 over a 24000-tick day at 20 tps.
//
//
// USING IT
//
// Importable anywhere that is not a startup-critical shader:
//
//     #moj_import <anion:slipspace.glsl>
//
// That covers core/item and core/sky. It does NOT cover core/position_tex_color
// (the end sky): that shader also backs GUI_TEXTURED_SNIPPET, which
// pipeline/mojang_logo uses, so it is compiled before resource packs exist and
// #moj_import is unavailable to it. For that one, paste everything between the
// PASTE BEGIN / PASTE END markers below.
//
//
// TUNING
//
// Every knob is #ifndef-guarded, so an includer can override any of them by
// defining it *before* the import. The look is driven mostly by SLIP_THRESH and
// SLIP_SHARP (how thin and how bright the fractures are) and SLIP_RATE (how
// often they light up).
//==========================================================================//

// ---------------------------- PASTE BEGIN --------------------------------

// --- the wall ---
// SLIP_AXIS is the band's *normal*, not the direction the gradient runs. Tilting
// it away from straight up tilts the band away from horizontal by the same
// angle: the default is 12.3 deg off vertical, so the band sits 12.3 deg off the
// horizon.
#ifndef SLIP_AXIS
#define SLIP_AXIS normalize(vec3(0.28, 1.0, 0.12))   // band plane normal
#endif
#ifndef SLIP_LIGHT
#define SLIP_LIGHT vec3(0.40, 0.41, 0.44)            // centre of the band
#endif
#ifndef SLIP_DARK
#define SLIP_DARK vec3(0.006, 0.006, 0.008)          // above and below it
#endif
#ifndef SLIP_BAND_WIDTH
#define SLIP_BAND_WIDTH 0.48                         // half-width, in |dot| units
#endif
#ifndef SLIP_FALLOFF
#define SLIP_FALLOFF 4.8                             // >1 tightens the band core
#endif
// Meander. SLIP_WAVE is the amplitude in the same units as dot(d, SLIP_AXIS),
// so it is directly comparable to SLIP_BAND_WIDTH: 0.22 against a width of 0.58
// swings the centre line by about a third of the half-width. 0.0 gives the old
// perfectly flat band back.
#ifndef SLIP_WAVE
#define SLIP_WAVE 0.22                               // centre-line displacement
#endif
#ifndef SLIP_WAVE_SCALE
#define SLIP_WAVE_SCALE 1.1                          // low = long lazy curves
#endif
#ifndef SLIP_WAVE_OCT
#define SLIP_WAVE_OCT 5                              // 1 = smooth, 4+ = ragged
#endif
#ifndef SLIP_WIDTH_VAR
#define SLIP_WIDTH_VAR 0.25                          // swell/pinch, fraction of width
#endif
#ifndef SLIP_DRIFT
#define SLIP_DRIFT 0.00005                           // radians/sec, noise only
#endif

// --- fractures ---
#ifndef SLIP_CRACK
#define SLIP_CRACK vec3(0.88, 0.90, 0.97)            // faintly cool white
#endif
#ifndef SLIP_CRACK_SCALE
#define SLIP_CRACK_SCALE 5.6                         // fractures per radian-ish
#endif
#ifndef SLIP_WARP
#define SLIP_WARP 0.55                               // 0 = smooth, high = jagged
#endif
#ifndef SLIP_THRESH
#define SLIP_THRESH 0.72                             // where a ridge becomes a crack
#endif
#ifndef SLIP_SHARP
#define SLIP_SHARP 6.0                               // higher = thinner filaments
#endif

// --- occasional intervals ---
#ifndef SLIP_HALO
#define SLIP_HALO 1.95                               // fat companion to SLIP_SHARP
#endif

#ifndef SLIP_REGION_LO
#define SLIP_REGION_LO 0.28
#endif
#ifndef SLIP_REGION_HI
#define SLIP_REGION_HI 0.64
#endif
// --- crack pulsing ---
#ifndef SLIP_RATE
#define SLIP_RATE 0.1                               // fracture cycles per second
#endif
#ifndef SLIP_IDLE
#define SLIP_IDLE 0.18                               // glow when nothing is firing
#endif
#ifndef SLIP_PULSE_SPREAD
#define SLIP_PULSE_SPREAD 3.0                        // independent fronts across the sky
#endif
#ifndef SLIP_PULSE_RISE
#define SLIP_PULSE_RISE 0.06                         // attack, fraction of a cycle
#endif
#ifndef SLIP_PULSE_FALL
#define SLIP_PULSE_FALL 0.45                         // decay end, fraction of a cycle
#endif
#ifndef SLIP_PULSE_BASE
#define SLIP_PULSE_BASE 0.45                         // lit region between flashes
#endif
#ifndef SLIP_PULSE_GAIN
#define SLIP_PULSE_GAIN 1.7                          // extra brightness at peak
#endif

// Splinter mask ramp. This has to be a ramp rather than a bare threshold - see
// the note at the branch itself.
#ifndef SLIP_SPLINTER_LO
#define SLIP_SPLINTER_LO 0.04
#endif
#ifndef SLIP_SPLINTER_HI
#define SLIP_SPLINTER_HI 0.9
#endif

// Fractures fade out as they approach the band. LO must stay above zero: the
// smoothstep is then flat at |h| = 0, so the kink in abs() sits inside a region
// that is already clamped to zero and never shows.
#ifndef SLIP_CRACK_FADE_LO
#define SLIP_CRACK_FADE_LO 0.15
#endif
#ifndef SLIP_CRACK_FADE_HI
#define SLIP_CRACK_FADE_HI 0.74
#endif

// --- red lightning ---
#ifndef SLIP_BOLTS
#define SLIP_BOLTS 3                                 // strikes tracked at once
#endif
#ifndef SLIP_BOLT_COLOR
#define SLIP_BOLT_COLOR vec3(0.8, 0.13, 0.08)
#endif
#ifndef SLIP_BOLT_LIFE
#define SLIP_BOLT_LIFE 0.55                          // seconds a strike lasts
#endif
#ifndef SLIP_BOLT_PERIOD
#define SLIP_BOLT_PERIOD 0.05                         // min seconds between a slot's strikes
#endif
#ifndef SLIP_BOLT_PERIOD_VAR
#define SLIP_BOLT_PERIOD_VAR 10.0                    // random extra on top of that
#endif
#ifndef SLIP_BOLT_FLICKER
#define SLIP_BOLT_FLICKER 40.0                       // strobe rate during a strike
#endif
#ifndef SLIP_BOLT_LEN
#define SLIP_BOLT_LEN 0.5                            // half-length, tangent-plane units
#endif
#ifndef SLIP_BOLT_W
#define SLIP_BOLT_W 0.0022                            // core thickness
#endif
#ifndef SLIP_BOLT_JAG
#define SLIP_BOLT_JAG 12.0                           // kinks per unit length
#endif
#ifndef SLIP_BOLT_AMP
#define SLIP_BOLT_AMP 0.05                           // how far it wanders
#endif
#ifndef SLIP_BOLT_EDGE
#define SLIP_BOLT_EDGE 1.0                           // edge softness, in pixels
#endif
#ifndef SLIP_BOLT_GLOW
#define SLIP_BOLT_GLOW 3.0                           // halo radius, x core width
#endif
#ifndef SLIP_BOLT_GLOW_GAIN
#define SLIP_BOLT_GLOW_GAIN 0.08                     // halo brightness, 0 disables
#endif

//--------------------------------------------------------------------------//
// Noise. Everything is slip_-prefixed because this file gets pasted into
// shaders that already define hash/noise/fbm under those bare names.
//--------------------------------------------------------------------------//

// Dave Hoskins' hash33. Pure multiplies and fract; the obvious
// fract(sin(dot(...)) * big) form runs sin on the special function unit at
// roughly quarter rate, and the noise below calls this eight times per sample.
vec3 slip_hash33(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return -1.0 + 2.0 * fract((p.xxy + p.yxx) * p.zyx);
}

float slip_hash31(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Gradient noise in 3D. Fed a direction it covers the sphere with no seam,
// unlike a 2D lookup on longitude/latitude.
float slip_noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(dot(slip_hash33(i + vec3(0, 0, 0)), f - vec3(0, 0, 0)),
                       dot(slip_hash33(i + vec3(1, 0, 0)), f - vec3(1, 0, 0)), u.x),
                   mix(dot(slip_hash33(i + vec3(0, 1, 0)), f - vec3(0, 1, 0)),
                       dot(slip_hash33(i + vec3(1, 1, 0)), f - vec3(1, 1, 0)), u.x), u.y),
               mix(mix(dot(slip_hash33(i + vec3(0, 0, 1)), f - vec3(0, 0, 1)),
                       dot(slip_hash33(i + vec3(1, 0, 1)), f - vec3(1, 0, 1)), u.x),
                   mix(dot(slip_hash33(i + vec3(0, 1, 1)), f - vec3(0, 1, 1)),
                       dot(slip_hash33(i + vec3(1, 1, 1)), f - vec3(1, 1, 1)), u.x), u.y), u.z);
}

float slip_fbm(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * slip_noise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// Ridged multifractal. 1 - abs(noise) turns the zero crossings into creases,
// and squaring sharpens them; stacking octaves at a non-integer lacunarity
// keeps them from lining up on the lattice, which is what makes the result read
// as splintering rather than as a grid.
float slip_ridged(vec3 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        float n = 1.0 - abs(slip_noise(p * freq));
        n *= n;
        sum += n * amp;
        norm += amp;
        freq *= 2.17;
        amp *= 0.55;
    }
    return sum / norm;
}

//--------------------------------------------------------------------------//
// Red lightning.
//
// The segment falloff is the shooting-star function from the galaxy shader:
// clamp the projection onto the bolt axis, measure perpendicular distance,
// smoothstep that into a line, then taper along its length. Two things are
// different.
//
// First, it runs on a tangent plane to the sphere instead of in screen space.
// The original was deliberately screen-space - a shooting star is a thing
// crossing your view - but a bolt has to stay put on the sky, and the obvious
// direction-space fix of atan()/latitude coordinates would put a seam down the
// back of the sky. A gnomonic projection about the bolt's own centre has no
// seam anywhere in the hemisphere it covers, and the `facing` cutoff discards
// the other hemisphere before any of the work is done.
//
// Second, the straight segment is displaced perpendicular by noise along its
// length, which is what turns a streak into a bolt.
//--------------------------------------------------------------------------//
vec3 slip_bolts(vec3 d, float time) {
    vec3 acc = vec3(0.0);

    // Angular size of one pixel, used below to keep the bolt edge exactly one
    // pixel wide however close or far the sky is.
    //
    // This MUST be computed here, before the loop. fwidth() is a derivative,
    // and derivatives are undefined under non-uniform control flow - the two
    // `continue`s below mean neighbouring pixels in a 2x2 quad routinely take
    // different paths, so calling fwidth() inside the loop would return garbage
    // on exactly the pixels that matter. Hoisting it out keeps the call in
    // uniform flow.
    float pix = max(length(fwidth(d)), 1e-6);

    for (int i = 0; i < SLIP_BOLTS; i++) {
        float id = float(i);

        // Each slot fires once per period, on its own schedule.
        float period = SLIP_BOLT_PERIOD
                     + slip_hash31(vec3(id, 7.0, 13.0)) * SLIP_BOLT_PERIOD_VAR;
        float lt = time + slip_hash31(vec3(id, 3.0, 1.0)) * 200.0;
        float cyc = floor(lt / period);
        float a = fract(lt / period) * period / SLIP_BOLT_LIFE;
        if (a > 1.0) continue;                        // dark for most of the period

        float env = smoothstep(0.0, 0.06, a) * smoothstep(1.0, 0.25, a);
        env *= 0.55 + 0.45 * sin(a * SLIP_BOLT_FLICKER + cyc * 3.0);   // flicker
        if (env <= 0.0) continue;

        vec3 seed = vec3(id, cyc, 5.0);
        vec3 c = normalize(slip_hash33(seed) + vec3(0.001, 0.002, 0.003));

        float facing = dot(d, c);
        if (facing < 0.25) continue;                  // wrong side of the sky

        vec3 up = abs(c.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3 uax = normalize(cross(up, c));
        vec3 vax = cross(c, uax);
        vec2 p = vec2(dot(d, uax), dot(d, vax)) / facing;

        float ang = slip_hash31(seed + 11.0) * 6.283185;
        vec2 dirv = vec2(cos(ang), sin(ang));
        float segLen = SLIP_BOLT_LEN * (0.6 + 0.8 * slip_hash31(seed + 23.0));

        float along = clamp(dot(p, dirv), -segLen, segLen);
        vec2 perp = vec2(-dirv.y, dirv.x);
        float jag = slip_noise(vec3(along * SLIP_BOLT_JAG, cyc, id)) * SLIP_BOLT_AMP;

        float dist = length(p - (dirv * along + perp * jag));

        // Solid core with a one-pixel edge, rather than a gradient all the way
        // to the centre. smoothstep(W, 0.0, dist) - what this used to be - has
        // no flat top at all: every pixel of the bolt sits somewhere on the
        // ramp, so the whole thing reads as a soft smear whatever W is, and
        // shrinking W only makes it a fainter smear.
        //
        // Widening the transition into pixel units instead keeps the edge as
        // tight as it can be without aliasing: the bolt is fully lit inside its
        // radius, fully dark outside, and the ramp is only ever about one pixel
        // across no matter how near or far the sky is.
        float aa = pix * SLIP_BOLT_EDGE / max(facing, 0.25);
        float core = 1.0 - smoothstep(SLIP_BOLT_W - aa, SLIP_BOLT_W + aa, dist);

        // Faint halo so a distant bolt does not thin out to nothing. Set
        // SLIP_BOLT_GLOW_GAIN to 0.0 for a hard-edged filament with no bloom.
        float glow = smoothstep(SLIP_BOLT_W * SLIP_BOLT_GLOW, 0.0, dist);

        float u = (along + segLen) / (2.0 * segLen);
        float taper = u * (1.0 - u) * 4.0;            // 1 mid-bolt, 0 at both ends

        acc += SLIP_BOLT_COLOR * (core + glow * SLIP_BOLT_GLOW_GAIN) * taper * env;
    }

    return acc;
}

//--------------------------------------------------------------------------//
// The sky itself.
//--------------------------------------------------------------------------//
// `detail` multiplies the noise domains only. It exists because a flat window
// subtends a narrow cone - a 3-block window at 3 blocks spans about 54 deg, and
// at SLIP_CRACK_SCALE that is under one noise lattice cell across. Sampling one
// cell of a ridged field gives you two or three enormous smooth creases, which
// read as bands slicing the aperture into quadrants rather than as fractures.
// Pass a larger detail for small apertures. The band gradient deliberately does
// NOT scale, so the wall stays consistent between a window and the open sky.
vec3 slipspace_detail(vec3 dir, float time, float detail) {
    vec3 d = normalize(dir);

    // The noise domain rotates slowly; the band axis does not. Drifting both
    // would make the whole sky appear to roll, which reads as the player
    // spinning rather than as the void moving.
    float a = time * SLIP_DRIFT;
    float ca = cos(a);
    float sa = sin(a);
    vec3 q = vec3(d.x * ca - d.z * sa, d.y, d.x * sa + d.z * ca);

    // ---- 1. the wall ----------------------------------------------------
    // A band centred on the plane perpendicular to SLIP_AXIS, falling to black
    // toward both poles.
    //
    // Two noise fields break up the perfect great circle:
    //
    //   * `wave` displaces the band COORDINATE before the profile is taken.
    //     Warping the input bends the centre line into a meander; scaling the
    //     output afterwards would only make the whole band brighter and dimmer
    //     in patches, which is not the same thing at all.
    //   * `width` modulates the half-width separately, so the band swells and
    //     pinches along its length instead of holding one thickness.
    //
    // Both sample q directly rather than q * detail. The band is deliberately
    // detail-independent so a flat window and the open sky agree on where it
    // is; scaling the meander with detail would put it in a different place in
    // each.
    float wave = slip_fbm(q * SLIP_WAVE_SCALE + vec3(41.0, 13.0, 17.0), SLIP_WAVE_OCT);
    float width = SLIP_BAND_WIDTH
                * (1.0 + slip_fbm(q * SLIP_WAVE_SCALE * 0.55 + vec3(7.0, 23.0, 3.0), 2)
                         * SLIP_WIDTH_VAR);

    // The profile is built on h*h rather than abs(h). Both are symmetric, but
    // abs() has a derivative discontinuity at h = 0, and that lands exactly on
    // the brightest line of the sky - it showed up as a hard crease running
    // down the middle of the band. h*h is smooth there. The clamp is safe for
    // the same reason at the far edge, since SLIP_FALLOFF > 1 flattens the
    // approach to zero.
    float h = dot(d, SLIP_AXIS) + wave * SLIP_WAVE;
    float hn = h / max(width, 0.05);
    float g = pow(clamp(1.0 - hn * hn, 0.0, 1.0), SLIP_FALLOFF);

    float mottle = slip_fbm(q * 2.2 * detail, 3) * 0.5 + 0.5;
    vec3 col = mix(SLIP_DARK, SLIP_LIGHT, g) * (0.82 + 0.36 * mottle);

    // ---- 2. fractures ---------------------------------------------------
    vec3 wp = q * SLIP_CRACK_SCALE * detail;

    // Domain warp before the ridges, not after. Warping the input is what
    // bends the creases into splinters; warping the output would only blur
    // them.
    vec3 warp = vec3(slip_noise(wp * 0.45 + 11.3),
                     slip_noise(wp * 0.45 + 31.7),
                     slip_noise(wp * 0.45 + 57.1)) * SLIP_WARP;

    float r = slip_ridged(wp + warp, 4);

    // Rescale before the power. The raw ridged field rarely reaches 1.0 - that
    // needs every octave to peak together - so applying pow() directly would
    // crush even the real ridges to nothing and force an absurd exponent.
    float rr = clamp((r - SLIP_THRESH) / (1.0 - SLIP_THRESH), 0.0, 1.0);

    float cracks = pow(rr, SLIP_SHARP);

    // Fat, dim version of the same field, used twice: as the glow bleeding
    // into the void around a fracture, and as the mask that keeps the fine
    // splinters clustered along the main breaks instead of scattered evenly.
    float halo = pow(rr, SLIP_HALO);

    // Splinters, masked to the neighbourhood of the main breaks.
    //
    // The mask must RAMP rather than switch. An earlier version used a bare
    // `if (halo > 0.12)` and added the splinter term at full strength inside it,
    // which meant the term jumped from 0 to as much as 0.07 across the contour
    // where halo crosses 0.12. Those contours are smooth curves, so they showed
    // up as clean lines drawn across the sky - very obvious through a window,
    // where a couple of them cross and slice the aperture into quadrants.
    // Multiplying by the smoothstep makes the contribution reach zero exactly
    // where the branch turns off, so the branch is a pure early-out again.
    //
    // Measured over 40k uniform directions the branch is taken for 27% of the
    // sky and discards 0.65% of the total crack energy.
    float splinter = smoothstep(SLIP_SPLINTER_LO, SLIP_SPLINTER_HI, halo);
    if (splinter > 0.0) {
        float fr = slip_ridged(wp * 3.1 + warp * 0.7, 2);
        float frr = clamp((fr - SLIP_THRESH) / (1.0 - SLIP_THRESH), 0.0, 1.0);
        cracks += pow(frr, SLIP_SHARP * 0.7) * halo * splinter * 0.6;
    }

    // ---- 3. occasional intervals ----------------------------------------
    // Fractures only open up in patches...
    float region = smoothstep(SLIP_REGION_LO, SLIP_REGION_HI,
                              slip_fbm(q * 1.6 * detail, 2) * 0.5 + 0.5);

    // ...and each patch lights on its own schedule. The phase varies smoothly
    // with direction rather than per lattice cell, so fronts sweep across the
    // sky instead of popping in on cell boundaries. The x3 wraps the phase
    // several times over the sphere, which is what gives several independent
    // fractures firing at once.
    float phase = fract(time * SLIP_RATE
                      + (slip_fbm(q * 1.1 * detail + 19.0, 2) * 0.5 + 0.5) * SLIP_PULSE_SPREAD);
    float flash = smoothstep(0.0, SLIP_PULSE_RISE, phase)
                * smoothstep(SLIP_PULSE_FALL, SLIP_PULSE_RISE * 0.8, phase);

    // Fractures die out as they approach the band. The wall is intact where it
    // is lit; it only breaks up out in the dark.
    float bandFade = smoothstep(SLIP_CRACK_FADE_LO, SLIP_CRACK_FADE_HI, abs(h));

    float amount = cracks * (SLIP_IDLE + region * (SLIP_PULSE_BASE + SLIP_PULSE_GAIN * flash)) * bandFade;

    // ---- 4. composite ---------------------------------------------------
    // Additive: a fracture is an opening onto something brighter, not paint on
    // top of the wall.
    col += SLIP_CRACK * amount;
    col += SLIP_CRACK * amount * amount * 0.6;                              // white-hot core
    col += SLIP_CRACK * halo * region * bandFade * (0.03 + 0.09 * flash);   // bleed into the void

    col += slip_bolts(d, time);

    return col;
}

// Open sky: the shell, or a dimension's sky renderer.
vec3 slipspace(vec3 dir, float time) {
    return slipspace_detail(dir, time, 1.0);
}

// ----------------------------- PASTE END ---------------------------------
