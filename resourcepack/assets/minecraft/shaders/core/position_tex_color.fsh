#version 330

/////////////////////
///// UNIFORM IMPORTS
/////////////////////

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

//////////////////////
///// HELPER FUNCTIONS
//////////////////////

#define DUST_OPACITY 0.15       // How dark are the dust lanes? (0.0 to 1.0)
#define GLOW_INTENSITY 0.4     // How bright is the galactic core?
#define GALAXY_TILT 2.7       // The angle of the milky way in the sky (in radians)
#define M_PI 3.1415926535897932384626433832795

// --- Helper Functions from Galaxy Shader ---

// A 3D hash. Returns a pseudo-random vector, each component roughly -1..1.
//
// This is Dave Hoskins' hash33, which mixes purely with multiplies and fract.
// The obvious version is fract(sin(dot(...)) * bigNumber), but sin runs on the
// special function unit at roughly quarter rate, and noise() calls this eight
// times per sample. Three sines per call across every octave was the single
// most expensive thing in this shader.
//
// It also distributes better than the sin version, which visibly bands once
// the input coordinates get large.
vec3 hash( vec3 p ) {

    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);

    return -1.0 + 2.0 * fract((p.xxy + p.yxx) * p.zyx);

}

// Gradient (Perlin-style) noise in 3D. Feed it a normalized direction times a
// density and it covers the sphere with no seam, unlike a 2D lookup on
// longitude/latitude.
float noise( in vec3 p ) {
    vec3 i = floor( p ); // which lattice cell we are in
    vec3 f = fract( p ); // where we are inside that cell, 0..1

    vec3 u = f*f*(3.0-2.0*f); // smoothstep curve, flat at both ends

    // Eight corners of the cell. For each one: hash a gradient vector, then dot
    // it with the offset from that corner to us. Collapse the eight results in
    // pairs along x, then y, then z.
    return mix( mix( mix( dot( hash( i + vec3(0.0,0.0,0.0) ), f - vec3(0.0,0.0,0.0) ),
                          dot( hash( i + vec3(1.0,0.0,0.0) ), f - vec3(1.0,0.0,0.0) ), u.x),
                     mix( dot( hash( i + vec3(0.0,1.0,0.0) ), f - vec3(0.0,1.0,0.0) ),
                          dot( hash( i + vec3(1.0,1.0,0.0) ), f - vec3(1.0,1.0,0.0) ), u.x), u.y),
                mix( mix( dot( hash( i + vec3(0.0,0.0,1.0) ), f - vec3(0.0,0.0,1.0) ),
                          dot( hash( i + vec3(1.0,0.0,1.0) ), f - vec3(1.0,0.0,1.0) ), u.x),
                     mix( dot( hash( i + vec3(0.0,1.0,1.0) ), f - vec3(0.0,1.0,1.0) ),
                          dot( hash( i + vec3(1.0,1.0,1.0) ), f - vec3(1.0,1.0,1.0) ), u.x), u.y), u.z );
}

// Fractal Brownian Motion (FBM) to create "cloudy" texture.
float fbm(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 8.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// --- Helper Functions from Stars & Streaks Shader ---

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 randColor(vec2 seed) {
    return vec3(rand(seed + 13.1), rand(seed + 37.7), rand(seed + 91.3));
}

// 3D versions of the two above, for anything keyed to a direction rather than
// to a screen position.
float rand3(vec3 co) {
    return fract(sin(dot(co, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

vec3 randColor3(vec3 seed) {
    return vec3(rand3(seed + 13.1), rand3(seed + 37.7), rand3(seed + 91.3));
}

// shooting star
vec3 renderStreak(float streakId, vec2 p, float time) {
    const float speed = 2.0;
    const float travelTime = 1.0 / speed;

    vec2 seed_id = vec2(streakId);
    float timeOffset = rand(seed_id + 17.0) * 200.0;
    float cyclePeriod = travelTime + 0.5 + rand(seed_id + 29.0) * 15.;

    float localTime = time + timeOffset;
    float timeInCycle = mod(localTime, cyclePeriod);

    if (timeInCycle > travelTime) {
        return vec3(0.0);
    }
    
    float cycleID = floor(localTime / cyclePeriod);
    vec2 run_seed = vec2(streakId, cycleID);
    
    float a = timeInCycle / travelTime;

    float ang = rand(run_seed) * 6.283;
    vec2 dir  = vec2(cos(ang), sin(ang));
    vec2 offset = vec2(-dir.y, dir.x) * (rand(run_seed * 9.8) * 2.0 - 1.0) * 0.8;
    
    vec2 center = dir * 1.4 * (a * 2.0 - 1.0) + offset;
    
    const float segLen = 0.2;
    float clampedProj = clamp(dot(p - center, dir), -segLen, segLen);
    float line = smoothstep(0.001, 0.0, length((p - center) - dir * clampedProj));

    float streakAlpha = line 
                      * (smoothstep(0.0, 0.15, a) * smoothstep(1.0, 0.85, a))
                      * ((clampedProj + segLen) / (2.0 * segLen));

    return randColor(run_seed) * streakAlpha;
}

///////////////////
///// MAIN PIPELINE
///////////////////

void main() {

    // this check isolates the end skybox from the rest of position_tex_color's targets.
    // ProjMat checks what projection mode the verticies are being drawn in,
    // while the color check ensures that we only target the end skybox (not the block or flame overlays).
    // the *reason* we check both is to prevent any gui color that matches
    // the end sky grey from getting the end sky shader override applied to it.
    //
    // tested BEFORE the vanilla path so end sky pixels skip the Sampler0 fetch
    // entirely - we overwrite that result anyway. neither input to this test
    // needs the texture.
    bool isEndSky = ProjMat[3][3] == 0.
                 && all(lessThan(abs(vertexColor.rgb - vec3(40.0/255.0)), vec3(0.01)));

    if (!isEndSky) {

        // vanilla code start
        vec4 color = texture(Sampler0, texCoord0) * vertexColor;

        // this allows transparent ui elements to actually be transparent.
        // if this check is removed, black boxes are drawn over transparent sections!
        if (color.a == 0.0) {
            discard;
        }

        fragColor = color * ColorModulator;
        // vanilla code end

        return;

    }

    {

        // Shadertoy's iTime is in SECONDS. GameTime is the fraction of a
        // Minecraft day, and a day is 24000 ticks at 20 tps = 1200 seconds.
        float iTime = GameTime * 1200.0;

        // The view direction for this pixel. The end sky cube is centred on the
        // camera, so its vertex position doubles as a world space ray.
        vec3 dir = normalize(Pos);

        // --- PART 1: GALAXY BACKGROUND ---

        // 1. SETUP COORDINATES
        // Tilt the galactic plane by rotating the direction itself, in 3D.
        // Rotating a flat uv with a mat2 instead would smear near the poles,
        // because that is not a real rotation of the sphere.
        float ca = cos(GALAXY_TILT);
        float sa = sin(GALAXY_TILT);
        vec3 g = vec3(dir.x * ca - dir.y * sa,
                      dir.x * sa + dir.y * ca,
                      dir.z);

        // Band coordinates. x runs the long way around the galactic plane, y is
        // the distance away from that plane. atan wraps at the back of the sky,
        // but only |x| is ever used below, so the wrap never shows.
        vec2 rotated_uv = vec2(atan(g.z, g.x) / M_PI, g.y);

        // 2. DEFINE THE MILKY WAY'S BASIC SHAPE
        // pow() compiles to exp2(y * log2(x)) - two special-function-unit ops.
        // For small integer exponents, repeated multiplies are strictly cheaper
        // and exact. These two run for every single pixel.
        float bandFalloff = 1.0 - abs(rotated_uv.y);
        float bandShape = bandFalloff * bandFalloff * bandFalloff * 0.2;

        float coreGlow = 1.0 - smoothstep(0.0, 1.0, length(rotated_uv * vec2(0.5, 1.0)));
        float cg2 = coreGlow * coreGlow;
        coreGlow = cg2 * cg2 * coreGlow * GLOW_INTENSITY;

        float milkyWay = bandShape + coreGlow;

        // 3. GENERATE THE CLOUDY TEXTURES
        // These sample 3D noise along the direction itself, so they are
        // seamless everywhere on the sphere.
        //
        // Everything below only ever modulates bandShape, which falls off as the
        // cube of the distance from the galactic plane. Past |g.y| = 0.72 the
        // whole block contributes less than 1/255 to the final color, so we skip
        // it. That is 28% of the sphere's solid angle for free - the measure of a
        // sphere is uniform in y, so the threshold IS the fraction.
        if (abs(g.y) < 0.72) {

            // Glowing Gas Clouds
            // 4 octaves, not 5. gas_uv is g * 12 and fbm starts at frequency 8
            // doubling each octave, so octave 5 lands at 12 * 8 * 16 = 1536
            // cycles around the sphere. That is far under one pixel at any sane
            // resolution, so it was contributing shimmer rather than detail.
            vec3 gas_uv = g * 12.0 + vec3(123.45, 678.9, 345.67);
            float gasFBM = fbm(gas_uv, 4);
            gasFBM = (gasFBM + 1.0) * 0.5;
            milkyWay += gasFBM * bandShape * 0.5;

            // Dark Dust Lanes
            vec3 dust_uv = g * 6.0 + vec3(456.7, 890.12, 234.56);

            // 2 octaves each, not 4. This is a domain warp whose result is scaled
            // by 0.3 and added to a coordinate - only its low frequencies displace
            // anything visible. The old 4-octave version spent 12 of the shader's
            // 24 total octaves here, half the entire cost, on detail that moved
            // the sample point by a fraction of a lattice cell.
            vec3 dust_distort = vec3(fbm(dust_uv + 15.5, 2),
                                     fbm(dust_uv + 33.3, 2),
                                     fbm(dust_uv + 51.1, 2)) * 0.3;

            // 5 octaves, not 7. Same Nyquist argument as the gas clouds: at 6 and
            // 7 this reached 1536 and 3072 cycles around the sphere.
            float dustFBM = fbm(dust_uv + dust_distort, 5);
            dustFBM = (dustFBM + 1.0) * 0.5;
            float dustMask = smoothstep(0.45, 0.7, dustFBM);

            // 4. COMBINE GALAXY LAYERS
            milkyWay *= (1.0 - dustMask * DUST_OPACITY);

        }

        milkyWay = max(0.0, milkyWay);

        // 5. COLORING THE GALAXY
        vec3 galaxyColor1 = vec3(0.1, 0.2, 0.4);
        vec3 galaxyColor2 = vec3(0.3, 0.4, 0.5);
        vec3 galaxyColor3 = vec3(0.3, 0.4, 0.5);

        vec3 galaxyBaseColor = mix(galaxyColor1, galaxyColor2, smoothstep(0.0, 0.1, milkyWay));
        galaxyBaseColor = mix(galaxyBaseColor, galaxyColor3, smoothstep(0.3, 0.9, milkyWay));

        vec3 skyColor = vec3(0.01, 0.02, 0.05);
        vec3 galaxyFinalColor = mix(skyColor, galaxyBaseColor, milkyWay);

        // --- PART 2: STARS & SHOOTING STARS (FOREGROUND) ---

        vec3 starsAndStreaksColor = vec3(0.0);

        // Grid based twinkling stars. The lattice is cut out of direction space
        // now instead of screen space, so the stars stay pinned to the sky.
        float starDensity = 90.0;
        vec3 starCell = floor(dir * starDensity);
        float starValue = rand3(starCell);
        float prob = 0.95;

        if (starValue > prob) {
            // where we are inside the cell, recentred to -0.5..0.5
            vec3 cellLocal = fract(dir * starDensity) - 0.5;
            float twinkleSpeed = 1.0 + rand3(starCell + 42.0) * 4.0;
            float phaseOffset = (starValue - prob) / (1.0 - prob) * M_PI * 2.0;
            float t = 0.9 + 0.2 * sin(iTime * twinkleSpeed + phaseOffset);

            // radial falloff, then a high power to pull it into a tight point
            float base = max(0.0, 1.0 - length(cellLocal) * 2.0);
            float b2 = base * base;
            float b4 = b2 * b2;
            base = b4 * b4 * t * t;

            vec3 starTint = mix(vec3(2.0), randColor3(starCell), rand3(starCell + 123.4) * 0.7);
            starsAndStreaksColor += base * starTint;
        }
        // A second, much finer lattice replaces the old per-pixel "salt and
        // pepper" pass, which only worked because it was keyed to screen pixels.
        else {
            vec3 fineCell = floor(dir * starDensity * 6.0);
            float fineValue = rand3(fineCell);

            if (fineValue > 0.996) {
                vec3 fineLocal = fract(dir * starDensity * 6.0) - 0.5;
                float r = rand3(fineCell + 7.0);
                float base = max(0.0, 1.0 - length(fineLocal) * 2.0);
                float fb2 = base * base;
                base = fb2 * fb2 * fb2 * r * (0.25 * sin(iTime * (r * 5.0) + 720.0 * r) + 0.75);

                vec3 starTint = mix(vec3(1.0), randColor3(fineCell), rand3(fineCell + 3.3) * 0.8);
                starsAndStreaksColor += base * starTint;
            }
        }

        // Shooting streaks stay in screen space deliberately. They are
        // transient things crossing your view, not fixed points on the sky.
        // Note the 2.0 - the original had 1.0, which shoved the centre of the
        // coordinate system off into a corner.
        vec2 screenUV = (2.0 * gl_FragCoord.xy - ScreenSize) / ScreenSize.y;

        const int NUM_STREAKS = 2;
        for (int i = 0; i < NUM_STREAKS; i++) {
            starsAndStreaksColor += renderStreak(float(i), screenUV, iTime);
        }

        // --- PART 3: FINAL COMPOSITION ---

        vec3 finalColor = galaxyFinalColor + starsAndStreaksColor;
        fragColor = vec4(finalColor, 1.0);

    }

}
