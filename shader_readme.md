# Minecraft 26.2 vanilla shader pipeline — capability notes

Everything below was read out of the actual 26.2 client, not from memory or wiki:

```
~/.local/share/PrismLauncher/libraries/com/mojang/minecraft/26.2/minecraft-26.2-client.jar
```

That jar ships with readable class, method and field names, so the render-graph
wiring (`LevelRenderer`, `GameRenderer`, `PostChain`, `PostChainConfig`,
`RenderPipelines`, `LevelTargetBundle`, `BlendFunction`, `DepthStencilState`)
could be disassembled directly with `javap -c`. Anything I could not confirm
from bytecode or from a vanilla shader source file is explicitly marked
**(unverified)**.

To re-extract the vanilla assets:

```sh
unzip -o -q minecraft-26.2-client.jar \
  'assets/minecraft/shaders/*' 'assets/minecraft/post_effect/*' -d vanilla
```

---

## 1. What a resource pack actually controls

### 1.1 Three overridable resource classes

| Path | What it is | Can you add new ones? |
| --- | --- | --- |
| `assets/minecraft/shaders/core/<name>.vsh/.fsh` | Programs bound to Java-defined pipelines | **No.** Only the 40 fixed names below are ever loaded. |
| `assets/minecraft/shaders/post/<name>.fsh`, `shaders/core/screenquad.vsh` | Fragment programs for post passes | **Yes** — any name, as long as a post-effect JSON references it. |
| `assets/<ns>/post_effect/<id>.json` | Post chain definitions | New files load fine, but nothing will ever *run* them. Only six IDs are invoked from Java. |
| `assets/<ns>/shaders/include/<name>.glsl` | `#moj_import` targets | **Yes**, any namespace. `ShaderManager` resolves includes as plain resource IDs under `shaders/include/`, so `#moj_import <anion:sdf.glsl>` → `assets/anion/shaders/include/sdf.glsl`. |

The 40 core shader names in 26.2:

```
animate_sprite(.vsh) animate_sprite_blit animate_sprite_interpolate blit_screen
block entity glint gui item lightmap panorama particle position position_color
position_tex position_tex_color debug_point screenquad sky stars terrain text
text_background rendertype_beacon_beam rendertype_clouds rendertype_crumbling
rendertype_end_portal rendertype_entity_shadow rendertype_leash
rendertype_lightning rendertype_lines rendertype_outline rendertype_water_mask
rendertype_world_border
```

Includes shipped by vanilla: `animation_sprite chunksection dynamictransforms
fog globals light matrix projection sample_lightmap`.

### 1.2 Hard limits (checked, not assumed)

- **`com.mojang.blaze3d.shaders.ShaderType` has exactly two values: `VERTEX`,
  `FRAGMENT`.** There is no geometry, tessellation or compute stage anywhere in
  the pipeline. A shader can *move* and *delete* vertices; it can never create
  them. Every "more geometry" technique below is therefore either (a) making the
  game submit geometry through a data-driven system, (b) hijacking a draw call
  that already exists, or (c) fragment-side raymarching.
- **Core shaders cannot sample the framebuffer.** Samplers come from
  `BindGroupLayout`s built in Java (`RenderPipelines`); a pack cannot add a
  `uniform sampler2D` that isn't already in the layout. Any effect that needs to
  read the rendered scene *must* go through a post chain.
- **Resource packs cannot define render pipelines.** `RenderPipelines` is a Java
  static-init class; there is no `pipeline/*.json` resource directory. Blend
  functions, cull, depth state, vertex format and shader defines are all fixed.
- **No MRT.** A post pass has one output target. A core shader has one
  `out vec4 fragColor` (except where Java declares more — none do).
- **Everything is `RGBA8_UNORM`.** `MainTarget`, the entity outline target and
  every post internal target are 8-bit. There is no HDR buffer, so bloom and
  wide blurs will band; do your thresholding on luminance and accept it.

### 1.3 Reversed-Z depth

`DepthStencilState.DEFAULT` is `(CompareOp.GREATER_THAN_OR_EQUAL, writeDepth =
true)`, and `GameRenderer` clears the main depth texture to `0.0`. 26.2 uses a
**reversed depth buffer**: `1.0` is at the near plane, `0.0` is the far plane /
sky. Any depth comparison you write in a post shader must be flipped relative to
what older pack tutorials say — "closer" is `depth > other`.

---

## 2. Frame graph order (from `LevelRenderer.render` / `GameRenderer.render`)

```
clear pass                     (main color+depth)
addSkyPass                     -> sky, stars, celestial, sunrise_sunset, end_sky
addMainPass                    -> terrain, entities, block entities, outline
                                  geometry (into entity_outline target),
                                  item-in-hand; translucent too unless Fabulous
POST CHAIN "entity_outline"    if PreparedFrame.hasAnyOutline()
addCloudsPass
addWeatherPass
POST CHAIN "transparency"      if Fabulous graphics
addAlwaysOnTopPass
--- frame graph executes ---
LevelRenderer.doEntityOutline()  blits entity_outline over main (alpha blend)
POST CHAIN "creeper"/"spider"/"invert"   if a mob post effect is active
clearDepthTexture(main, 0.0)
GUI
```

The important consequence: **the `entity_outline` post chain is a general-purpose
full-screen pass over the finished world**, and it runs before clouds, weather
and the outline composite.

---

## 3. Render targets and who can see them

`LevelTargetBundle` defines seven target IDs and three permission sets. Each post
chain is loaded with an allow-list; referencing a target outside it is a load
error.

| Chain ID | Trigger | Allowed external targets |
| --- | --- | --- |
| `minecraft:blur` | menu background blur | `minecraft:main` |
| `minecraft:creeper`, `minecraft:spider`, `minecraft:invert` | spectating that mob | `minecraft:main` |
| **`minecraft:entity_outline`** | **any entity in view has an outline** | **`minecraft:main`, `minecraft:entity_outline`** |
| `minecraft:transparency` | Fabulous graphics only | `main`, `translucent`, `item_entity`, `particles`, `weather`, `clouds` |

```java
MAIN_TARGETS    = Set.of(MAIN);
OUTLINE_TARGETS = Set.of(MAIN, ENTITY_OUTLINE);      // <- both
SORTING_TARGETS = Set.of(MAIN, TRANSLUCENT, ITEM_ENTITY, PARTICLES, WEATHER, CLOUDS);
```

**This is the single most useful thing in the whole pipeline.** The
`entity_outline` chain can *read and write* `minecraft:main`, including
`use_depth_buffer: true` on it, in every graphics mode, and its only prerequisite
is that one entity somewhere in view is glowing. It is a scene-wide programmable
post-processing slot that Mojang left open.

The `translucent`/`item_entity`/`particles`/`weather`/`clouds` targets are
**only created when the transparency chain exists** (Fabulous). In Fast/Fancy
they are null and translucent geometry goes straight into `main`.

### 3.1 The entity outline target

- `new TextureTarget("Entity Outline", w, h, /*useDepth=*/true, RGBA8_UNORM)` —
  screen-sized, **with its own depth buffer**.
- Cleared each frame by the frame graph's `clear` pass.
- Filled by `pipeline/outline_cull` and `pipeline/outline_no_cull`, both running
  `core/rendertype_outline` with vertex format `POSITION_TEX_COLOR`, topology
  `QUADS`, sampler `Sampler0`.
- Because it has its own depth buffer and never sees terrain depth, glowing
  entities are **not occluded by the world** — that is why glow shows through
  walls. Glowing entities *do* occlude each other correctly.
- Vanilla fragment shader:

```glsl
vec4 color = texture(Sampler0, texCoord0);
if (color.a == 0.0) discard;
fragColor = vec4(ColorModulator.rgb * vertexColor.rgb, ColorModulator.a);
```

  You own this shader. It is effectively a **free G-buffer keyed to arbitrary
  entity geometry**: whatever you write here lands in an RGBA8 screen-space
  buffer with matching depth, and the `entity_outline` post chain can read both.

- Composite: `RenderTarget.blitAndBlendToTexture` → `pipeline/entity_outline_blit`
  = `core/screenquad` + `core/blit_screen`, blend
  `(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, alphaSrc=ZERO, alphaDst=ONE)`, NEAREST
  clamped sampler, no depth test. **Alpha blend, not additive.** Writing `a = 0`
  in the last chain pass makes the composite a no-op, which is how you take full
  control (see §7).

---

## 4. Post-effect JSON: the parts nobody documents

From `PostChainConfig`, `PostChainConfig$InternalTarget`, `$Pass`,
`$TargetInput`, `$TextureInput`:

```jsonc
{
  "targets": {
    "my_half_res": {
      "width": 960,          // optional, defaults to screen size
      "height": 540,         // optional
      "persistent": false,   // <- survives across frames when true
      "clear_color": -16777216 // <- ARGB int, applied each frame
    }
  },
  "passes": [
    {
      "vertex_shader": "minecraft:core/screenquad",
      "fragment_shader": "anion:post/my_pass",
      "inputs": [
        { "sampler_name": "Main",  "target": "minecraft:main", "bilinear": true },
        { "sampler_name": "Depth", "target": "minecraft:main", "use_depth_buffer": true },
        { "sampler_name": "Noise", "location": "anion:textures/effect/bluenoise.png",
          "width": 64, "height": 64, "bilinear": false }
      ],
      "output": "minecraft:main",
      "uniforms": {
        "MyConfig": [
          { "name": "Radius", "type": "float", "value": 8.0 },
          { "name": "Tint",   "type": "vec4",  "value": [1,0.6,0.2,1] }
        ]
      }
    }
  ]
}
```

Notes that matter:

- **`persistent: true`** makes the target an *external* frame-graph resource
  created once via `getOrCreatePersistentTarget` and never cleared. That is a
  **frame-to-frame history buffer** — temporal accumulation, trails, TAA-style
  smearing, slow-decay glow. Non-persistent internal targets go through
  `createInternal` and are cleared to `clear_color` every frame.
- **Texture inputs** (`location`/`width`/`height`) bind an arbitrary resource-pack
  PNG as a sampler. LUTs, blue noise, gradient ramps, mask atlases.
- Sampler naming: `"sampler_name": "In"` → `uniform sampler2D InSampler` in GLSL.
  Names must be unique within a pass (`"Encountered repeated sampler name: "`).
- **`SamplerInfo` is per-pass and grows with your input count.** `PostPass`
  writes `OutSize` first, then one `vec2` per input in declaration order:

```glsl
layout(std140) uniform SamplerInfo {
    vec2 OutSize;   // output target size
    vec2 InSize;    // input #1 size
    vec2 In2Size;   // input #2 size  <- valid, vanilla just never declares them
};
```

- Post internal targets **do** get a depth attachment (`useDepth = true` in the
  descriptor), but nothing clears it per pass and the pass pipeline inherits
  `DepthStencilState.DEFAULT` (GEQUAL + depth write). Don't build anything on
  post-target depth; use encoded depth in a colour channel instead.
- A pass does **not** clear its output before drawing (`createRenderPass` passes
  `Optional.empty()` for both colour and depth clear). The full-screen triangle
  covers everything anyway, but this is why "read main, write main" works: the
  read is a bound sampler, the write is an overwrite.
- Passes use `POST_PROCESSING_SNIPPET` = globals bind group + `TRIANGLES`, no
  blend function → **output overwrites, never blends**. To add light to `main`
  you must sample `main` in the same pass and output the sum.

### 4.1 Uniforms available inside a post fragment shader

Only these:

- `SamplerInfo` (above)
- your own JSON-declared uniform blocks
- **`Globals`** — `POST_PROCESSING_SNIPPET` includes `GLOBALS_SNIPPET`, so
  `#moj_import <minecraft:globals.glsl>` works. `box_blur.fsh` already relies on
  it:

```glsl
ivec3 CameraBlockPos; vec3 CameraOffset; vec2 ScreenSize;
float GlintAlpha;     float GameTime;    int MenuBlurRadius; int UseRgss;
```

`RenderSystem.bindDefaultUniforms` does call `setUniform` for `Projection`,
`Fog`, `Globals` and `Lighting` on the post pass, **but the pass's
`BindGroupLayout` only contains samplers + `SamplerInfo` + your blocks + Globals**.
`GlProgram.setupBindGroupLayouts` binds uniform blocks by walking the *layout*,
so a `Fog` or `Projection` block declared in a post `.fsh` gets no real buffer
bound to it. **Do not use `FogColor` as a channel in post shaders** — it is
garbage there, even though it is your channel of choice in core shaders.
**(Partially unverified: it may compile and silently read binding 0 rather than
erroring; either way it is unusable.)**

There is **no camera matrix in post**. This is the single biggest constraint on
world-space post effects, and §6.2 is the workaround.

---

## 5. Core shader facts worth having in one place

### 5.1 Camera-relative position is available almost everywhere

`entity.vsh`, `item.vsh`, `particle.vsh`, `sky.vsh` all feed `Position` straight
into `fog_spherical_distance()`, which is `length(pos)`. So **`Position` in those
shaders is already camera-relative world space** (world-axis aligned; the camera
rotation lives in `ModelViewMat`). Therefore:

```glsl
vec3 viewRay   = normalize(Position);                          // world-space ray
vec3 cameraPos = vec3(CameraBlockPos) - CameraOffset;          // exact camera pos
vec3 worldPos  = Position + cameraPos;                         // absolute coords
```

`block.vsh` uses `Position + ModelOffset`; `terrain.vsh` uses
`Position + (ChunkPosition - CameraBlockPos) + CameraOffset`, which confirms
`cameraPos == CameraBlockPos - CameraOffset` (the comment in this repo's
`sky.fsh` says the same thing).

That means any core shader can compute **stable absolute world coordinates** —
world-anchored noise, y-level gating, coordinate-hash effects, per-block
variation that doesn't swim when you walk.

### 5.2 Shader defines split shared programs

Several pipelines share one shader and are told apart by defines. This is free
branching with zero runtime cost:

| Define | Where | Values |
| --- | --- | --- |
| `PORTAL_LAYERS` | `rendertype_end_portal` | **15 = end portal, 16 = end gateway** |
| `ALPHA_CUTOUT` | `terrain`, `block`, `entity`, `item` | `0.5` = cutout terrain/block, `0.1` = everything else |
| `EMISSIVE` | `entity` | set on `eyes`, `energy_swirl`, `entity_translucent_emissive` — skips lightmap |
| `NO_OVERLAY` | `entity` | skips hurt-flash overlay sampler |
| `PER_FACE_LIGHTING` | `entity` | front/back face colours, uses `gl_FrontFacing` |
| `NO_CARDINAL_LIGHTING` | `entity` | raw vertex colour, no directional light |
| `APPLY_TEXTURE_MATRIX` | `entity` | `TextureMat` animates UV (`energy_swirl`, `breeze_wind`) |
| `DISSOLVE` | `entity_cutout_dissolve` | adds a real extra sampler, `DissolveMaskSampler` |
| `IS_GUI` | `gui_text` vs world text | |
| `UseRgss` (uniform, not define) | `terrain` | user's texture-filtering setting |

`#if PORTAL_LAYERS == 16` gives you **two completely independent programmable
in-world window shaders** out of one source file.

### 5.3 Blend functions (`BlendFunction`)

| Name | srcColor | dstColor | srcAlpha | dstAlpha |
| --- | --- | --- | --- | --- |
| `LIGHTNING` | SRC_ALPHA | ONE | — | — |
| `GLINT` | SRC_COLOR | ONE | ZERO | ONE |
| `OVERLAY` | SRC_ALPHA | ONE | ONE | ZERO |
| `TRANSLUCENT` | SRC_ALPHA | ONE_MINUS_SRC_ALPHA | ONE | ONE_MINUS_SRC_ALPHA |
| `TRANSLUCENT_PREMULTIPLIED_ALPHA` | ONE | ONE_MINUS_SRC_ALPHA | ONE | ONE_MINUS_SRC_ALPHA |
| `ADDITIVE` | ONE | ONE | — | — |
| `ENTITY_OUTLINE_BLIT` | SRC_ALPHA | ONE_MINUS_SRC_ALPHA | ZERO | ONE |
| `INVERT` | ONE_MINUS_DST_COLOR | ONE_MINUS_SRC_COLOR | ONE | ZERO |

`ADDITIVE` is used by `pipeline/energy_swirl`; `GLINT` (`SRC_COLOR, ONE`) is
additive-ish and used by `pipeline/glint`. Both are free additive draw slots.

### 5.4 `box_blur.fsh` has a user-controlled radius

```glsl
float actualRadius = Radius >= 0.5 ? round(Radius) : float(MenuBlurRadius);
```

Set `Radius` to `0.0` in your JSON and the blur radius becomes the player's
**"Menu Background Blurriness" video setting**, readable from `Globals` in any
post shader. That's a free per-user intensity slider for any effect.

---

## 6. Cross-cutting: how to tell a shader "this pixel is special"

Ranked by robustness. Everything in the four lists below depends on one of these.

1. **Magic colour in the texture.** Give the block/entity/item texture an exact
   RGB the vanilla palette never produces, test for it in the fragment shader
   with a small epsilon. Survives atlas repacking and resolution changes. This is
   what `position_tex_color.fsh` in this repo already does for the End sky
   (`vertexColor.rgb ≈ 40/255`).
2. **`FogColor`** (core shaders only, via `fog.glsl`). Driven by biome/dimension
   fog settings from a datapack, so it is a **global mode register** — this repo
   already uses it as the shader-selection entry point. Not available in post.
3. **`ColorModulator` / vertex colour.** Per-draw ARGB: glow/team colour, dyed
   leather, potion colour, beacon beam colour, `dust` particle colour. A `dust`
   particle's RGB is arbitrary 24-bit data you can set per-particle from a
   command — a genuine per-instance parameter channel.
4. **`ProjMat[3][3] == 0.0`** separates perspective (world) from orthographic
   (GUI, item icons) for shaders shared between them.
5. **World position** (§5.1) — region, y-level, distance-to-camera gating.
6. **Lightmap `UV2`** — block light 15 as a cheap "this is emissive" flag.
7. **Alpha above the cutout threshold** — for `ALPHA_CUTOUT` pipelines, alpha in
   `(threshold, 1.0]` is visually unused on opaque pipelines and can carry a few
   bits. Fragile on anything that blends. **(unverified for terrain solid, where
   the alpha ends up in the main target and the transparency chain tests
   `color.a == 0.0`.)**
8. **Shader defines** (§5.2) — free compile-time branching per pipeline.

---

## 7. List A — drawing custom geometry attached to entities

No resource pack can issue a draw call. So: make the game submit your geometry,
or rewrite geometry it already submits, or fake volume in the fragment stage.

### A1. Display entities (the real answer for actual new geometry)
`item_display`, `block_display`, `text_display` ridden by / mounted on the
target entity, or moved by a datapack every tick. Arbitrary transform matrix,
billboard modes, scale, per-entity glow colour. They render through:
- `item_display` → `pipeline/item_cutout` / `item_translucent` (`core/item`,
  vertex format `ENTITY`)
- `block_display` → `pipeline/solid_block` / `cutout_block` / `translucent_block`
  (`core/block`)
- `text_display` → world text pipelines

The geometry itself comes from a normal model JSON, so Blockbench output is
directly usable. Your shaders then identify it with a magic colour (§6.1).

### A2. Item models on equipment / held slots
`assets/<ns>/items/*.json` + a model with arbitrary geometry, worn or held.
`select`/`condition`/`composite` item-model components let one item ID resolve to
different meshes at runtime. Rendered through `core/item`.

### A3. Equipment and trim layers
`assets/<ns>/equipment/*.json`. Fixed humanoid/animal geometry, but each layer is
an **extra draw pass over the same mesh** (`armor_cutout_no_cull`,
`armor_decal_cutout_no_cull`, `armor_translucent`), which a vertex shader can
extrude into a shell. Trims give a second decal layer for free.

### A4. Hijack an existing per-entity draw call
These pipelines already re-draw entity geometry and are yours to rewrite:

| Pipeline | Shader | Blend | What it gives you |
| --- | --- | --- | --- |
| `energy_swirl` | `core/entity` + `EMISSIVE NO_OVERLAY NO_CARDINAL_LIGHTING APPLY_TEXTURE_MATRIX ALPHA_CUTOUT` | **ADDITIVE** | A full second copy of the whole entity model, additively blended, with an animated `TextureMat`. Extrude along `Normal` in the vsh → a genuine 3D aura shell. Triggered by charged-creeper / wither-armour layers. |
| `eyes` | `core/entity` + `EMISSIVE NO_OVERLAY NO_CARDINAL_LIGHTING` | TRANSLUCENT | Extra emissive layer pass. |
| `entity_shadow` | `core/rendertype_entity_shadow` | TRANSLUCENT | A ground-projected quad under **every** entity with a shadow radius. Free anchored quad — perfect raymarch host (A7). |
| `glint` | `core/glint` | GLINT (additive-ish) | Duplicate of item geometry for every enchanted item. `GlintAlpha` global is a free scalar. |
| `entity_cutout_dissolve` | `core/entity` + `DISSOLVE` | — | The only entity pipeline with a **second sampler** (`DissolveMaskSampler`). |
| `leash`, `end_crystal_beam`, `lightning`, `dragon_rays`, `beacon_beam_*`, `breeze_wind` | various | various | Existing world-anchored strips/beams whose vertices a vsh can relocate into any shape. |

### A5. Vertex-shader reshaping
`entity.vsh` receives `Position, Color, UV0, UV1(overlay), UV2(lightmap), Normal`.
You can extrude, twist, billboard, or collapse. `gl_VertexID` addresses individual
vertices deterministically, so a model with N spare quads can be rebuilt into a
procedural shape. You cannot add vertices — but you *can* delete them (push
outside clip space or make degenerate), which means "replace the vanilla mesh
with mine" is possible if your mesh has ≤ the original vertex count.

### A6. Particles as programmable point sprites
`core/particle` — camera-facing quads, spawned per tick at entity positions by a
datapack or plugin. `dust` particles carry an arbitrary RGB (a 24-bit parameter) and a
scale, both readable as `vertexColor` / vertex spread. Combined with A7 this is
the cheapest way to hang dozens of independent procedural objects off an entity.

### A7. Fragment raymarched impostors — arbitrary "geometry" from one quad
Any of the above quads can render a full SDF/volume in the fragment shader, with
`gl_FragDepth` written for correct intersection against the world. You have the
world-space ray (§5.1) and the camera position, so this is straightforward:

```glsl
// in the .vsh
out vec3 rayWorld;      // = Position, camera-relative world space
// in the .fsh
vec3 ro = vec3(CameraBlockPos) - CameraOffset;   // camera world pos
vec3 rd = normalize(rayWorld);
float t = raymarch(ro, rd);                      // your SDF
if (t < 0.0) discard;
// reversed-Z: recompute clip depth from t and write gl_FragDepth
```

One quad = arbitrarily complex shape. This is the only real answer to "more
geometry than the game submitted".

**What does not work:** geometry/tessellation shaders (no such stage),
instancing control (Java-side), adding vertices in a vsh, or getting a resource
pack to register a new render type.

---

## 8. List B — distorting space behind a shaded plane

Core shaders can never read the scene, so every one of these is a post chain.
Two entry points exist; pick by which constraint you can live with.

### B1. Entity-outline chain as a universal screen-space pass — **recommended**
Works in Fast/Fancy/Fabulous. Cost of entry: one glowing entity in view
(`PreparedFrame.hasAnyOutline()`).

Recipe:
1. Place an invisible-textured, glowing `item_display` shaped like the wall.
2. Rewrite `core/rendertype_outline.fsh` to write a **mask + payload** for that
   entity instead of a flat outline colour (§9 C5 for the encoding).
3. Rewrite `assets/minecraft/post_effect/entity_outline.json` to a chain that
   reads `minecraft:entity_outline` (colour **and** `use_depth_buffer: true`),
   `minecraft:main` (colour and depth), blurs `main` where the mask is set, and
   writes the result back to `minecraft:main`.
4. Final pass writes `a = 0` into `minecraft:entity_outline` so the Java blit
   contributes nothing.

Depth gating (reversed-Z, closer = larger):

```glsl
float maskDepth  = texture(MaskDepthSampler, texCoord).r;
float sceneDepth = texture(MainDepthSampler, texCoord).r;
bool  behindPlane = sceneDepth < maskDepth;      // scene is farther than the plane
```

Since the outline target ignores world depth, this comparison is also what stops
the effect leaking through terrain that occludes the plane.

### B2. Transparency chain (Fabulous only)
`transparency.fsh` receives all six layers with depth. Mark the wall with a
translucent block whose `terrain.fsh`/`block.fsh` output carries a signature
colour; then in the composite, where the translucent layer matches, sample
`MainSampler` with displaced UVs instead of straight compositing. This gives real
refraction with correct layer sorting — but you have to reimplement the 6-layer
insertion sort, and it silently does nothing outside Fabulous.

### B3. Pure depth-driven blur (no mask at all)
In the outline chain, blur `main` wherever `mainDepth` is beyond a threshold from
a JSON uniform. A "fog wall"/DOF plane with zero marking infrastructure.

### B4. UV displacement instead of blur
Encode a 2D distortion vector (or a surface normal) in the mask's RG, then:

```glsl
vec2 off = (mask.rg * 2.0 - 1.0) * Strength / InSize;
fragColor = texture(MainSampler, texCoord + off);
```

Heat haze, glass refraction, gravitational lensing, cloaking shimmer. Works from
either entry point.

### B5. Reuse `post/box_blur.fsh`
It is already separable and exploits `GL_LINEAR` to halve the tap count. Chain it
horizontally then vertically per blur level; `Radius` comes from JSON, and
`Radius < 0.5` hands control to the player's menu-blur slider (§5.4).

### B6. Cheap wide radius via downsampled targets
Declare `"targets": { "half": { "width": 960, "height": 540 } }`, blur there,
upsample with `bilinear: true`. Note sizes are **absolute pixels, not fractions**,
so pick something sane and let `SamplerInfo` handle the ratio.

### B7. Temporal smear
`"persistent": true` target + `mix(history, current, 0.15)` = motion trails,
ghosting, "unstable space". Also the base for any accumulation effect.

### B8. Geometric distortion instead of screen-space
`terrain.vsh` can bend the world itself; you have exact world coordinates and
`GameTime`. This is real geometry displacement (no post chain, no glowing entity)
but it is global and can only be masked by world position or camera distance,
not by "behind this specific plane".

### B9. Fallback with no requirements at all
`rendertype_end_portal` already does `textureProj(Sampler0, texProj0)` — a
screen-space projected lookup into a *texture*. That is not the scene, but if you
feed it a panorama it reads as "space behind the plane" with zero setup and
correct depth occlusion. See list C.

---

## 9. List C — another skybox through a shaded plane, with masked volumetrics

### C1. End portal / end gateway — the best in-world window
`pipeline/end_portal` (`PORTAL_LAYERS = 15`) and `pipeline/end_gateway`
(`PORTAL_LAYERS = 16`) share `core/rendertype_end_portal`. Properties that make
this the strongest option:

- **Two independent programmable windows** from one file, split by
  `#if PORTAL_LAYERS == 16`.
- **Two samplers** (`Sampler0` = end sky texture, `Sampler1` = portal texture) —
  the only in-world geometry pipeline with a spare texture unit. Use `Sampler1`
  as a 3D-ish noise / cubemap-cross / LUT source.
- Opaque, depth-tested and depth-written → correct occlusion, no sorting bugs.
- Geometry is the portal block's top face or the gateway's full cube, so the
  window is masked exactly to the block.
- Placement is a normal block placement. No entities, no Fabulous, no glowing.

Skeleton:

```glsl
// rendertype_end_portal.vsh — add a camera-relative position output
out vec3 posWorldRel;
...
posWorldRel = Position;                     // camera-relative world space

// rendertype_end_portal.fsh
vec3 ro = vec3(CameraBlockPos) - CameraOffset;
vec3 rd = normalize(posWorldRel);
#if PORTAL_LAYERS == 16
    vec3 col = raymarchGatewayInterior(ro, rd);   // volumetric nebula, etc.
#else
    vec3 col = sampleCustomSky(rd);               // second skybox
#endif
fragColor = vec4(col, 1.0);
```

For volumetrics: march from the fragment's world position along `rd`, terminate
on your own SDF, and either keep the block-face depth (interior parallax, cheapest)
or write `gl_FragDepth` so the volume intersects world geometry properly.

### C2. Item model as a window — the easy way to put one anywhere
An `item_display` entity holding an item whose model is a flat quad is the most
practical window in the game. No block placement, no dimension restriction, free
positioning and rotation, arbitrary count, and it moves.

- **Nothing vanilla has to be overridden.** Put the definition at
  `assets/<ns>/items/<name>.json` and point any stack at it with the
  `minecraft:item_model` component (`DataComponents.ITEM_MODEL`). Combined with
  `minecraft:dyed_color` — a plain integer in 26.2, `DyedItemColor.rgb` through
  `ExtraCodecs.RGB_COLOR_CODEC` — read by a `minecraft:dye` tint source, that is
  the whole attachment mechanism, on any item, with no vanilla model replaced.
  The `minecraft:dye` *component* is unrelated; it only marks dye ingredients.
- It renders through `core/item` (`ITEM_SNIPPET`, vertex format `ENTITY`), which
  is the **only in-world geometry shader that receives a `Normal` attribute** —
  that matters a lot, see C8.
- `pipeline/item_cutout` and `pipeline/item_translucent` both run `core/item`, so
  one shader covers both. Neither calls `withCull(false)`, so items are
  **backface-culled**: a single quad is a one-sided window, which is what you
  want. A texture under `textures/item/` lands in the items atlas and therefore
  on `Sheets.cutoutItemSheet()` → `RenderPipelines.ITEM_CUTOUT`; see §13.2.
- `display: fixed` on the display entity keeps a real world orientation.
  `billboard: center` instead gives a window whose normal always faces the
  camera, which is occasionally what you want.

**Custom components are the parameter channel.** The item model format gives you
both variant selection and continuous per-stack data:

| Mechanism | What it gives the shader |
| --- | --- |
| `select` on `custom_model_data` (string), `context_dimension`, `context_entity_type`, `display_context`, `local_time`, `block_state`, `main_hand`, `trim_material` | a *different model/texture* → detected by magic colour or UV |
| `condition` on `custom_model_data` (flag), `has_component`, `keybind_down`, `view_entity`, `extended_view`, `using_item`, `selected`, `carried` | boolean model swap, including some that react to the viewer |
| `range_dispatch` on `custom_model_data` (float), `time`, `use_cycle`, `count`, `damage` | quantised continuous value → model swap |
| **`tints` + `minecraft:custom_model_data` tint source** | **arbitrary 24-bit RGB straight into the vertex colour, per stack** |

The tint route is the important one. `net.minecraft.client.color.item.CustomModelDataSource`
takes `index` and `default`:

```jsonc
{
  "model": {
    "type": "minecraft:model",
    "model": "anion:item/window_plane",
    "tints": [
      { "type": "minecraft:custom_model_data", "index": 0, "default": -1 },
      { "type": "minecraft:custom_model_data", "index": 1, "default": -1 },
      { "type": "minecraft:custom_model_data", "index": 2, "default": -1 }
    ]
  }
}
```

Each entry maps to a `tintindex` in the model's faces, and each pulls a separate
colour out of `custom_model_data.colors`. **A model with N tint-indexed faces
therefore carries N × 24 bits of per-stack shader parameters** — portal ID,
palette, animation phase, size, SDF parameters, whatever you want. Set them from
a datapack with `/item` and the `minecraft:custom_model_data` component.

One catch: `item.vsh` folds `Color` into the diffuse lighting before passing it
on, so `vertexColor` in `item.fsh` is already light-modulated. You own the vertex
shader — add a passthrough:

```glsl
// item.vsh
out vec4 rawColor;
...
rawColor = Color;      // untouched per-face tint = your parameter block
```

Read the parameter faces' colours from `rawColor`, and use the same tint on the
window face itself (or a magic texture colour) as the "this is a window" flag.

### C3. End sky (`pipeline/end_sky` → `core/position_tex_color`)
Already hijacked in this repo. Whole-dimension second sky, isolated by the
`ProjMat[3][3] == 0.0` + grey-colour test in `position_tex_color.fsh`. Good for
"the End is now a galaxy", not for a localised window.

### C4. Rebuilding the overworld sky
`core/sky` (POSITION only, fog-driven), `core/stars` (`ColorModulator` only),
`core/position_tex` via `pipeline/celestial` (sun/moon quads), `core/position_color`
via `pipeline/sunrise_sunset`, `core/rendertype_clouds`. Between them you can
replace the whole sky; `FogColor` is your per-biome/dimension selector.

### C5. Arbitrary-shape portal via post — the general case
Any shape, any dimension, any block or entity as the window. Requires the
outline-chain trick because **post shaders have no camera matrix**.

The workaround: **encode the view ray in the mask itself**, in the core shader
that draws the mask (which *does* have the camera), then decode in post.
RGBA8 gives you exactly enough:

```glsl
// --- in rendertype_outline.fsh (or a marked translucent block's shader) ---
// octahedral-encode the world-space view ray into RG (16 bits total)
vec2 octEncode(vec3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    vec2 e = n.xy;
    if (n.z < 0.0) e = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0,
                                                n.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}
fragColor = vec4(octEncode(normalize(posWorldRel)),   // RG: ray
                 clamp(length(posWorldRel) / 128.0, 0.0, 1.0),  // B: entry distance
                 1.0);                                          // A: coverage / id
```

```glsl
// --- in the post pass ---
vec3 octDecode(vec2 e) {
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
    float t = max(-n.z, 0.0);
    n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
    return normalize(n);
}
vec4 mask = texture(MaskSampler, texCoord);
if (mask.a > 0.0) {
    vec3 ro = vec3(CameraBlockPos) - CameraOffset + octDecode(mask.rg) * (mask.b * 128.0);
    vec3 rd = octDecode(mask.rg);
    fragColor = vec4(raymarchVolume(ro, rd), 1.0);   // masked volumetric sky
}
```

That one RGBA8 texel carries ray direction, entry distance and coverage — enough
to do fully world-correct volumetrics in a post pass that otherwise knows nothing
about the camera. **8 bits per channel is coarse**; octahedral RG is fine for a
sky lookup, marginal for tight SDF marching. Splitting the payload across a
second marker entity (or the `translucent` target in Fabulous) buys more bits.

### C6. Bounded volumes need an exit point
The outline target keeps only the nearest fragment, so a single marker gives you
entry depth only. Options, in order of practicality:
1. **Analytic exit** — define the volume as a sphere/box in world space and solve
   the exit intersection in the shader. Robust, cheap, no extra channels.
2. **Encode thickness** in the mask's B channel from the core shader (you know
   the model's local geometry there).
3. **Front hull in `entity_outline`, back hull in `translucent`** — only works in
   Fabulous, and costs you the transparency chain.

### C7. Masking geometry out entirely
`pipeline/water_mask` (`core/rendertype_water_mask`, writes only
`ColorModulator`, TRANSLUCENT blend) exists to punch water out behind boats. It
is a depth-writing, effectively-invisible primitive — usable as a "hole in the
world" stencil if you can get the game to draw it where you want.

**Dead end I checked:** `core/panorama` and `CubeMap` are main-menu only; there
is no world-facing cubemap sampler anywhere in the pipeline.

### C8. Window orientation and portal-local space

**Yes — the facing direction is recoverable, and you can build a full
portal-local coordinate frame and march shapes forward into the viewed space
from the aperture.** Three separate ways to get the normal, in order of quality.

**1. The `Normal` vertex attribute (item / entity shaders only).**
`core/item` and `core/entity` both declare `in vec3 Normal`, and it is already in
**world space**: `Lighting$Entry.LEVEL` feeds the shader the raw constants
`DIFFUSE_LIGHT_0 = normalize(0.2, 1.0, -0.7)` and
`DIFFUSE_LIGHT_1 = normalize(-0.2, 1.0, 0.7)` with no matrix applied, so for
`minecraft_mix_light(Light0_Direction, Light1_Direction, Normal, Color)` to
produce vanilla's camera-independent shading, `Normal` has to be in world axes.
The entity's pose (including the display entity's rotation) is baked into the
vertex data CPU-side; the camera lives in `ModelViewMat` and never touches
`Normal`. So for an `item_display` window:

```glsl
// item.vsh
out vec3 winNormal;
out vec3 posRel;      // camera-relative world position
...
winNormal = normalize(Normal);
posRel    = Position;
```

That is the window's facing, for free, per fragment.

**2. Screen-space derivatives of world position (works in _every_ shader).**
If the pipeline has no `Normal` — `core/block`, `core/terrain`,
`core/rendertype_end_portal`, `core/rendertype_outline` — reconstruct the
geometric normal:

```glsl
vec3 N = normalize(cross(dFdx(posRel), dFdy(posRel)));
N *= sign(dot(N, -normalize(posRel)));     // orient toward the camera
```

Exact on a flat quad (which a window is). Only breaks on curved/edge pixels,
because derivatives are per-2×2 quad.

**3. Bake it into the model.** Encode the normal (or a full tangent frame) as a
tint colour or a texture channel. Most robust, most setup. Not needed given 1
and 2.

#### Building the portal frame

The normal alone gives you an axis but no roll and no origin. For "shapes
anchored to the window", you want origin `O`, tangent `T`, bitangent `B`,
normal `N`.

**Tangent** — from the texture's U direction, which rotates with the model:

```glsl
vec3 dPx = dFdx(posRel), dPy = dFdy(posRel);
vec2 dUx = dFdx(texCoord0), dUy = dFdy(texCoord0);
float det = dUx.x * dUy.y - dUy.x * dUx.y;
vec3 T = normalize((dPx * dUy.y - dPy * dUx.y) / det);
vec3 B = cross(N, T);
```

**Origin** — the cheapest exact method is to let the texture carry the window's
local coordinates. Paint the window sprite as a ramp: R = local X in 0..1,
G = local Y in 0..1, B/A free for mask and ID. Then:

```glsl
vec4 t = texture(Sampler0, texCoord0);
vec2 local = (t.rg * 2.0 - 1.0) * HALF_SIZE;   // metres from window centre
vec3 O     = posRel - T * local.x - B * local.y;
```

A 256×256 ramp gives sub-millimetre resolution on a one-block window; the atlas
sampler is NEAREST, so resolution is the only limit, not filtering. For windows
snapped to the block grid you can skip all this and use
`O = floor(worldPos) + 0.5` instead.

#### Marching forward into the viewed space

With the frame in hand, transform camera and ray into portal space and start the
march at the aperture (local z = 0, "forward" = into the window):

```glsl
vec3 camPos  = vec3(CameraBlockPos) - CameraOffset;   // exact camera world pos
vec3 rdWorld = normalize(posRel);                     // world-space view ray
mat3 toLocal = transpose(mat3(T, B, -N));             // -N points into the portal

vec3 p0 = vec3(local, 0.0);            // this fragment, on the aperture plane
vec3 rd = normalize(toLocal * rdWorld);

float t = 0.0;
for (int i = 0; i < STEPS; ++i) {
    vec3 p = p0 + rd * t;              // p.z > 0 == behind the window
    float d = sceneSDF(p);             // your shapes, in window-local metres
    if (d < 0.001) break;
    t += d;
}
```

Everything in `sceneSDF` is now defined relative to the window opening: move or
rotate the display entity and the whole interior follows it rigidly. Shapes at
`p.z > 0` sit inside the viewed space and are clipped to the aperture for free,
because the quad is the only thing being shaded.

#### Gotchas that will actually bite you

- **Do not write a farther `gl_FragDepth` for interior shapes.** 26.2 is
  reversed-Z with `GEQUAL`, and terrain behind the window is already in the depth
  buffer. A farther depth fails the test and the shape vanishes. Keep the quad's
  depth for anything inside; interior parallax does not need real depth anyway.
  Writing a *nearer* depth is safe and is how you make something reach out of the
  window toward the viewer.
- **The aperture is the quad.** Nothing renders outside the window silhouette,
  and at grazing angles the aperture narrows to nothing. That is correct portal
  behaviour, but it means an interior object only "exists" while some part of it
  projects inside the quad.
- **Backface culling** makes an item-model window one-sided. Two back-to-back
  quads give you two different interiors from the two sides; on a no-cull
  pipeline use `gl_FrontFacing` instead.
- **Strip the vanilla shading.** `item.fsh` multiplies in `lightMapColor`,
  `overlayColor` and `apply_fog`. Branch those off for window fragments or the
  interior will be tinted by block light and faded by distance fog.
- **Derivative-based frames are undefined at the very edge pixels** of the quad
  where a 2×2 quad straddles the silhouette. Inset your ramp texture by a texel
  or clamp `local`.
- **Multiple windows cost nothing extra in the shader.** The frame is derived
  per-fragment, so ten display entities with ten different `custom_model_data`
  tints run the same code with different parameters.

If the effects you have planned need more than ~192 bits of per-window
parameters, or need genuine two-sided depth (front and back hull of a volume),
that is where this approach runs out and you move up to the post-chain route in
C5 — but everything described here works with no glowing entity, no Fabulous
requirement, and correct occlusion.

---

## 10. List D — bloom around certain entities

### D1. Rewrite `entity_outline.json` into a real bloom chain — **recommended**
Vanilla chain: `entity_sobel` → `entity_outline_box_blur` (H, r=2) →
`entity_outline_box_blur` (V, r=2) → `blit` → target `minecraft:entity_outline`,
then Java alpha-blends that over `main`.

Every one of those steps is yours. Replace with:

```jsonc
{
  "targets": {
    "bright": { "width": 640, "height": 360 },
    "swap":   { "width": 640, "height": 360 }
  },
  "passes": [
    { "fragment_shader": "anion:post/glow_threshold",
      "vertex_shader": "minecraft:core/screenquad",
      "inputs": [ { "sampler_name": "In", "target": "minecraft:entity_outline" } ],
      "output": "bright" },

    { "fragment_shader": "minecraft:post/box_blur",
      "vertex_shader": "minecraft:core/screenquad",
      "inputs": [ { "sampler_name": "In", "target": "bright", "bilinear": true } ],
      "output": "swap",
      "uniforms": { "BlurConfig": [ { "name": "BlurDir", "type": "vec2", "value": [1,0] },
                                    { "name": "Radius",  "type": "float", "value": 12.0 } ] } },

    { "fragment_shader": "minecraft:post/box_blur",
      "vertex_shader": "minecraft:core/screenquad",
      "inputs": [ { "sampler_name": "In", "target": "swap", "bilinear": true } ],
      "output": "bright",
      "uniforms": { "BlurConfig": [ { "name": "BlurDir", "type": "vec2", "value": [0,1] },
                                    { "name": "Radius",  "type": "float", "value": 12.0 } ] } },

    // additive composite: read main + glow, write main
    { "fragment_shader": "anion:post/glow_composite",
      "vertex_shader": "minecraft:core/screenquad",
      "inputs": [
        { "sampler_name": "Main",      "target": "minecraft:main" },
        { "sampler_name": "MainDepth", "target": "minecraft:main", "use_depth_buffer": true },
        { "sampler_name": "Glow",      "target": "bright", "bilinear": true },
        { "sampler_name": "MaskDepth", "target": "minecraft:entity_outline", "use_depth_buffer": true }
      ],
      "output": "minecraft:main" },

    // neutralise the vanilla blit: alpha 0 -> SRC_ALPHA blend is a no-op
    { "fragment_shader": "anion:post/zero",
      "vertex_shader": "minecraft:core/screenquad",
      "inputs": [ { "sampler_name": "In", "target": "bright" } ],
      "output": "minecraft:entity_outline" }
  ]
}
```

This is **true additive bloom**, which the vanilla composite path cannot give you
(`ENTITY_OUTLINE_BLIT` is `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`). It works in every
graphics mode. The only prerequisite is a glowing entity in view.

Occlusion fix — glowing entities ignore terrain depth, so raw bloom leaks through
walls. In `glow_composite`, reversed-Z:

```glsl
float sceneD = texture(MainDepthSampler, texCoord).r;
float maskD  = texture(MaskDepthSampler, texCoord).r;
float vis    = step(sceneD, maskD);    // 1 when the glowing surface is in front
fragColor = vec4(texture(MainSampler, texCoord).rgb + texture(GlowSampler, texCoord).rgb * vis, 1.0);
```

Use a soft `smoothstep` instead of `step` if you want the glow to bleed slightly
around occluders, which usually looks better.

### D2. Selecting *which* entities bloom
The outline colour is per-entity: `rendertype_outline.fsh` outputs
`ColorModulator.rgb * vertexColor.rgb`, and `ColorModulator` is the entity's
glow/team colour. So **`/team modify <name> color <colour>` becomes a bloom
profile selector** — match the colour in `glow_threshold` and pick intensity,
tint and radius per team. You also own `rendertype_outline.fsh` outright, so you
can write an explicit ID into a channel instead of relying on colour matching.

### D3. Category bloom via the transparency chain (Fabulous only)
`particles`, `item_entity`, `weather` and `clouds` arrive as separate targets
with depth. Bloom applied to `ItemEntitySampler` glows every dropped item;
applied to `ParticlesSampler` it glows every particle. No glowing entity needed,
but Fabulous-only and you must reimplement the layer sort.

### D4. Post-free glow: additive shell on `energy_swirl`
`pipeline/energy_swirl` is `ADDITIVE` and draws the entire entity model a second
time. Extrude along `Normal` in `entity.vsh` under a define check and fade alpha
with the extrusion distance:

```glsl
// entity.vsh
#if defined(EMISSIVE) && defined(APPLY_TEXTURE_MATRIX)   // energy_swirl only
    vec3 pos = Position + Normal * 0.15;
#else
    vec3 pos = Position;
#endif
```

This is a real 3D glow shell, works in every graphics mode, needs no post chain
and no glowing entity — but it only fires on entities that already have a
charged-creeper / wither-armour layer.

### D5. `pipeline/glint` as a halo channel
`GLINT` blend is `SRC_COLOR, ONE` (additive-weighted). Every enchanted item gets
a free duplicate draw through `core/glint`, with `GlintAlpha` as a ready-made
fade scalar. Rewrite it into a soft halo and any enchanted item blooms.

### D6. Billboard glow sprites
An `item_display` with a radial-gradient item model, parented to the entity,
through `pipeline/item_translucent`. Crude but universal, and it composites
correctly in every mode.

### D7. Temporal glow trails
`"persistent": true` accumulation target in the outline chain:
`newHistory = max(current, history * 0.9)`. Comet trails behind glowing entities.

### D8. Note: "entity-selected" and "scene-wide" are independent choices
Because the outline chain can read `main`, you can run a classic luminance-
threshold bloom over the **whole scene** while merely *using* a glowing entity as
the on/off switch. The trigger and the source do not have to be the same thing.

---

## 11. Things I checked that turn out not to work

- Geometry / tessellation / compute shaders — `ShaderType` has two values.
- Adding a sampler to a core shader — bind group layouts are Java-side constants.
- Reading the framebuffer from a core shader — no such sampler exists.
- New render pipelines or new render types from a resource pack.
- New post-effect IDs — only `blur`, `creeper`, `spider`, `invert`,
  `entity_outline`, `transparency` are ever requested by name.
- `Fog` / `Projection` / camera matrices inside post shaders — not in the post
  bind group layout, so nothing is bound to them.
- Multiple render targets from one pass.
- HDR anywhere — everything is `RGBA8_UNORM`.
- Fractional/relative post target sizes — `width`/`height` are absolute pixels.
- Depth in post internal targets — the attachment exists but is not managed;
  encode depth in a colour channel instead.
- Standard-direction depth comparisons — 26.2 is reversed-Z (`GEQUAL`, cleared to
  `0.0`).

## 12. Open questions worth testing in-game

- Whether an unbound `Fog` block in a post shader errors at link time on the
  Vulkan backend or silently reads binding 0 on GL. Either way it's unusable,
  but the failure mode determines whether it crashes the pack.
- Exact bit-stability of alpha as a side channel on `solid_terrain`, given the
  transparency chain's `color.a == 0.0` test.
- Whether `shouldShowEntityOutlines` can be false while `hasAnyOutline()` is
  true — if so, the chain runs but the vanilla blit is skipped, which is actually
  the ideal state for the §10 D1 technique.
- Whether a post pass may name the same target as both an input and its output
  in one pass (vanilla always ping-pongs, which suggests it cannot).

---

## 13. Working test build — the window item

Shipped in this pack. Everything here is verified: both shaders compile clean
under `glslangValidator` (with and without `ALPHA_CUTOUT` defined), both JSON
files parse, and the render path was traced through the 26.2 bytecode.

### 13.1 Files

| File | Role |
| --- | --- |
| `assets/anion/textures/item/window_ramp.png` | 64×64 UV ramp. R = local X, G = local Y (flipped so it runs bottom→top), B = `0xAA` signature, A = 255. 174 bytes. |
| `assets/anion/models/item/window_plane.json` | 1×1 zero-thickness plane, north + south faces, `tintindex: 0`, `shade: false`. |
| `assets/anion/items/window.json` | Item model definition: `minecraft:model` → the plane, `tints: [{ "type": "minecraft:dye", "default": 6967216 }]` (`0x6A4FB0`, red byte 106 → the galaxy). |
| `assets/anion/textures/item/sky_sphere.png` | 16×16 flat `(0, 0, 0x55, 255)`. Pure signature, no data. 86 bytes. |
| `assets/anion/models/item/sky_sphere.json` | Closed cube shell, 4×4 cells per face = 96 inward-facing quads. |
| `assets/anion/items/sky_sphere.json` | Item model definition for the walk-in shell, same dye tint. |
| `assets/anion/shaders/include/spherify.glsl` | The vertex-mutation method. See §14. |
| `assets/anion/shaders/include/slipspace.glsl` | The slipspace sky. See §15. |
| `assets/minecraft/shaders/core/item.vsh` | Vanilla + four extra varyings (`posRel`, `winNormal`, `rawColor`, `isWorld`) + the sphere remap. |
| `assets/minecraft/shaders/core/item.fsh` | Vanilla path untouched, plus the window and skybox branches. |

### 13.2 No vanilla item is overridden

The definition lives at `anion:window`, and any item stack points at it with the
`minecraft:item_model` component:

```
minecraft:paper[minecraft:item_model="anion:window", minecraft:dyed_color=11546150]
```

`minecraft:item_model` (`DataComponents.ITEM_MODEL`) replaces which item model
definition the stack resolves to, so nothing in `assets/minecraft/items/` is
touched and no vanilla item changes appearance. The base item is irrelevant —
`paper` here purely because it is inert.

The colour arrives through `minecraft:dyed_color`, which in 26.2 is a single-field
record (`DyedItemColor.rgb`) serialised with `ExtraCodecs.RGB_COLOR_CODEC`, so the
value is a plain integer or an `[r, g, b]` array. The `minecraft:dye` tint source
reads that component directly and falls back to the definition's `default`; it
does **not** require the separate `minecraft:dye` component, which only exists to
mark a stack as a dye ingredient. Setting `dyed_color` on any item works.

Crafting-table dyeing is a separate matter: `DyeRecipe` is a data-driven recipe,
so making this item dyeable at a table needs a datapack recipe. Setting the
component from a command, loot table or datapack — which is how a window would be
placed anyway — needs nothing extra.

The render path was checked end to end: the texture lives under `textures/item/`,
so it is registered in the **items** atlas (`assets/minecraft/atlases/items.json`
has a `directory` source with `prefix: "item/"` that applies to every namespace).
That routes the quad through `BakedQuad$MaterialInfo` → `Sheets.cutoutItemSheet()`
→ `RenderTypes.itemCutout` → `RenderPipelines.ITEM_CUTOUT` → **`core/item`**,
which is the pipeline that carries a `Normal` attribute. The earlier "unverified"
note in C2 is now resolved: an item-model window lands on `core/item`.

### 13.3 How the shader recognises a window

```glsl
bool isWindow = isWorld > 0.5                          // perspective pass only
             && color.a > 0.99
             && abs(color.b - 170.0/255.0) < 0.02;     // ramp signature
```

`isWorld` comes from `ProjMat[3][3] == 0.0`, evaluated in the vertex shader so
the fragment stage never touches the `Projection` block. Inventory icons,
item-frame GUI renders and any orthographic pass fall straight through to the
untouched vanilla path.

### 13.4 Exact local coordinates from a 64-px ramp

The ramp is quantised to 64 texels, which would show as stair-stepping in a
marched interior. `texCoord0` is a smooth interpolated varying, so the sub-texel
remainder recovers the exact position:

```glsl
vec4 ramp    = textureLod(Sampler0, texCoord0, 0.0);   // mip 0 = exact texel value
vec2 atlasPx = vec2(textureSize(Sampler0, 0));
vec2 sub     = fract(texCoord0 * atlasPx) - 0.5;       // where inside that texel
vec2 local   = vec2(ramp.r + sub.x / RAMP_PX,
                    ramp.g - sub.y / RAMP_PX);         // G is authored flipped
```

`textureSize()` and `textureLod()` are both core in GLSL 330. Because the sprite
is registered at native resolution, `RAMP_PX` is all the shader needs to know —
the atlas size and sprite placement cancel out. The result is smooth to float
precision, so the ramp resolution costs nothing.

### 13.5 The frame, scale-free

```glsl
vec2 dLx = dFdx(local), dLy = dFdy(local);
float det = dLx.x * dLy.y - dLy.x * dLx.y;
vec3 Tw = (dPx * dLy.y - dPy * dLx.y) / det;   // world vector per +1 local X
vec3 Bw = (dPy * dLx.x - dPx * dLy.x) / det;   // world vector per +1 local Y
```

Solving against `local` rather than `texCoord0` means the answer is already in
window units, so an `item_display` with any uniform scale works with no extra
bookkeeping — `length(Tw)` *is* the window's size in metres if you want it.
`N` comes from the `Normal` attribute, flipped toward the viewer;
`cross(Tw, Bw)` is the drop-in replacement for shaders that have no normal.

Then the ray, with `+z` pointing into the window:

```glsl
vec3 rd = normalize(vec3(dot(rdW, T), dot(rdW, B), dot(rdW, -N)));
vec3 ro = vec3(local - 0.5, 0.0);              // start on the aperture plane
```

### 13.6 Dye → effect

`rawColor` is the untouched face tint (the vanilla `vertexColor` has diffuse
lighting folded in, which destroys it as a data channel — hence the extra
varying). `shade: false` on the element keeps the face-direction shade factor out
of it, so the byte is the dye byte.

`int fx = int(clamp(rawColor.r * 4.0, 0.0, 3.999));`

| Red byte | Effect | Dyes that land here |
| --- | --- | --- |
| 0–63 | **0 — frame debug.** RG ramp, eighth grid, magenta origin dot, blue = how directly the ray enters. If this looks square and stable, everything else is trustworthy. | black, blue, cyan, light blue |
| 64–127 | **1 — slipspace.** Grey-to-black void with splintering fractures. Lives in `anion:slipspace.glsl`, shared with the shell and available to a dimension sky. Ignores the dye tint — the palette is the preset. See §15. | *undyed*, green, gray |
| 128–191 | **2 — shapes.** Five spheres and a floor raymarched **forward from the aperture**, animated, depth-faded. This is the one that proves the whole premise. | red, lime, purple, brown, light gray |
| 192–255 | **3 — tunnel.** Analytic ring intersections receding into the window. | white, yellow, orange, magenta, pink |

The full dye colour also tints effects 1–3.

### 13.7 Try it

```
/give @s minecraft:paper[minecraft:item_model="anion:window",minecraft:dyed_color=11546150]
/summon item_display ~ ~1 ~2 {item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:window","minecraft:dyed_color":11546150}},item_display:"fixed",billboard:"fixed",transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[2f,2f,2f],right_rotation:[0f,0f,0f,1f]}}
```

`11546150` is `0xB02E26`, vanilla red dye → effect 2. Swap it for `1908001`
(`0x1D1D21`, black dye) to get the debug frame, or drop the stack in an item frame
to see it without an entity. Omit `minecraft:dyed_color` entirely and the tint
source falls back to the definition's `default` — `0x6A4FB0`, which lands on the
purple galaxy. Bump `scale` and the window grows without distorting the interior
— that is the scale-free frame doing its job.

The same two components work on any item, so `anion:window` can ride on whatever
item your setup already registers rather than on `paper`.

Sanity checks worth doing in that order:

1. Dye black (`1908001`), `scale: [1,1,1]` — debug view should be a clean
   red/green ramp with a square grid and the magenta dot dead centre.
2. Set `scale: [3,3,3]` — grid stays square, dot stays centred. Confirms the
   frame is derived, not hardcoded.
3. Rotate the display with `left_rotation` — the grid rotates with the plane and
   the debug blue channel peaks when you look straight in.
4. Dye red and walk side to side — the spheres should parallax *inside* the
   window like real geometry, and get clipped by the window edge rather than
   spilling out.

### 13.8 Known limits of this build

- **No depth is written**, deliberately. Interior geometry sits at the quad's
  depth. Writing a farther `gl_FragDepth` would fail the reversed-Z `GEQUAL`
  test against whatever is already behind the window and the shapes would
  vanish. Nearer depth is safe if you want something to reach out.
- The signature test costs one `texture()` fetch that vanilla was doing anyway,
  and windows pay a second `textureLod()`. Ordinary items are unaffected.
- The GUI icon shows the raw ramp texture tinted by the dye. Add a
  `select` on `display_context` in the item definition if that bothers you.
- Edge-on views hit the `abs(det) > 1e-12` guard and fall back to a flat colour.
- Effect selection is 4 buckets of 64. If you want more than four types, or
  continuous parameters, switch the tint source to `minecraft:custom_model_data`
  and add more tint indices — see C2.

---

## 14. Walk-in skybox shell — `spherify.glsl`

Shipped as `assets/anion/shaders/include/spherify.glsl`, wired into `item.vsh`.
An `item_display` holding `anion:sky_sphere` becomes a localized bubble of sky:
walk into it and it surrounds you, walk out and it shrinks to a patch sitting
where the object is.

### 14.1 Why there is no "sphere around the entity" function

The obvious signature is `spherify(vertex, entityOrigin, radius)`. It cannot be
written for item or entity shaders in 26.2, and the reasons are worth recording
because they close off a whole family of ideas:

- **The pose is baked CPU-side.** `entity.vsh` and `item.vsh` both feed
  `Position` straight into `fog_spherical_distance()`, which is `length()`. So
  `Position` is already camera-relative world space and carries no separate
  model origin. `ModelViewMat` is therefore just the camera view matrix — there
  is no per-entity translation left in it to pull out.
- **`ModelOffset` is zero here.** `DynamicTransforms.ModelOffset` exists and
  `core/block` uses it, but only the four-argument
  `DynamicUniforms.writeTransform(Matrix4f, Vector4f, Vector3f, Matrix4f)`
  overload writes it, and item draws do not use that overload.
- **No vertex channel is wide enough.** The attributes are `Position`, `Color`,
  `UV0`, `UV1`, `UV2`, `Normal`. `Color` and the UVs are per-face constants you
  author, and a vanilla block model cannot give a quad arbitrary per-vertex UVs
  — a face gets one axis-aligned rect plus a rotation. There is no room to
  smuggle an origin through.

So the mapping is view-anchored. For a skybox that is not a compromise, it is
the more correct choice.

### 14.2 What view-anchoring actually does

```glsl
vec3 spherify_view(vec3 posRel, float radius) {
    return normalize(posRel) * radius;
}
```

Every vertex lands at exactly `radius` from the eye — which is the definition of
a skybox. Magnitude is discarded entirely, so the shell's **wall thickness and
tessellation do not affect the result at all**. The original geometry only
decides *which directions are covered*:

| Camera | Directions the shell spans | What you see |
| --- | --- | --- |
| inside the shell | all of them | a full sphere of sky around you |
| outside | the solid angle the object subtends | a patch of that sky sitting where the object is |

The transition happens exactly at the model's real surface, so **the object
stays localized in the world** even though the projection follows the camera.
Walking in opens the patch out until it fills your view. That is the effect you
wanted, and it falls out of `normalize()` for free.

The shell is opaque and writes depth, so terrain nearer than `radius` still
renders and everything beyond it is replaced by sky. Keep `SPHERE_RADIUS` near
half the display entity's world size and the two boundaries agree.

### 14.3 Winding: why the model has inward faces

Item pipelines are backface culled — neither `ITEM_CUTOUT` nor `ITEM_TRANSLUCENT`
calls `withCull(false)`. A normal cube would show you nothing from inside.

`sky_sphere.json` is generated with every face declared on the side pointing at
the model centre: the `+Z` wall gets a `north` face, the `-Z` wall a `south`
face, and so on. 4×4 cells per cube face, 96 quads total.

`spherify.glsl` also ships `spherify_view_flip()` for models you cannot
re-author. It is a point reflection through the camera, and `det(-I) = -1` in
three dimensions, so screen-space winding flips and culling reveals the far side
of the shell. Worth understanding what happens geometrically: negating all three
vertices leaves the geometric normal **unchanged** — both edge vectors flip and
`cross(-a, -b) == cross(a, b)` — while moving the face to the antipode. A face
that pointed away from the centre now sits opposite and points toward it. It is
only sound while you are inside a closed shell; from outside it puts the sky on
the wrong side of you.

### 14.4 Detection

The shell is the only thing whose vertices get moved, so the test has to happen
in the vertex shader, where the fragment-side signature check is not available
yet. `item.vsh` does a vertex texture fetch:

```glsl
if (ProjMat[3][3] == 0.0
 && abs(textureLod(Sampler0, UV0, 0.0).b - SPHERE_MAGIC) < SPHERE_TOL) {
    pos = spherify_view(Position, SPHERE_RADIUS);
}
```

GL 3.3 guarantees at least 16 vertex texture image units, and item vertex counts
are trivial, so the cost is not measurable. It is gated on the perspective test
so inventory icons skip it entirely.

`sky_sphere.png` is a flat 16×16 `(0, 0, 0x55, 255)` — pure signature, no data.
The two magics are `0xAA` (flat window) and `0x55` (shell), far enough apart that
no plausible mip filtering confuses them.

### 14.5 Tessellation is invisible

The fragment shader does **no frame reconstruction** for the shell. Because the
vertices are already on a sphere centred on the eye, the fragment's own
camera-relative position *is* the view ray:

```glsl
vec3 rd = normalize(posRel);
```

So the sky is exact however coarse the cube is — 4×4 cells per face is not a
quality compromise, it only sets how accurately the shell's *boundary* matches a
sphere for the walk-in transition. `item.vsh` assigns `posRel` from the mutated
position precisely so this stays true.

If you ever texture the shell rather than shading it from the ray, the
tessellation *does* start to matter, and `cube_to_sphere()` in the include is the
distortion-reducing map to use — plain `normalize()` bunches a uniform cube grid
up near face centres and stretches it at the corners.

### 14.6 Culling

`Display` sets `noCulling = true` in its constructor, and `updateCulling()`
re-derives it as `width == 0 && height == 0`. **Leaving `width` and `height` at
their defaults means the display entity is never frustum-culled** — exactly what
a shell larger than the screen needs. Do raise `view_range` though; it defaults
to `1.0` and still gates distance rendering.

### 14.7 Try it

```
/summon item_display ~ ~ ~ {item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:sky_sphere"}},item_display:"fixed",billboard:"fixed",view_range:16.0,transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[24f,24f,24f],right_rotation:[0f,0f,0f,1f]}}
```

`scale: 24` gives a 24-block shell, matching the default `SPHERE_RADIUS 24.0`.
No `dyed_color` means the definition's default applies → the purple galaxy.
Stand at the summon point and you are inside it; walk 12 blocks in any direction
and you cross out through the wall.

Checks worth doing:

1. Stand at the centre — full sky in every direction, terrain still visible out
   to ~24 blocks.
2. Walk out and turn around — the sky collapses to a patch hanging where the
   entity is.
3. Dye it black (`1908001`) — effect 0 on a shell is not meaningful (there is no
   window frame), but it confirms the dye channel reaches the shell.
4. Raise `scale` to `48f` and `SPHERE_RADIUS` to `48.0` together — the bubble
   gets bigger without the sky changing apparent size relative to it.

---

## 15. Slipspace — `slipspace.glsl`

`assets/anion/shaders/include/slipspace.glsl`. A grey-to-black void with bright
fractures splintering through the walls at irregular intervals. Direction-driven,
so one function serves the flat window, the walk-in shell and eventually a whole
dimension's sky:

```glsl
vec3 slipspace(vec3 dir, float time)   // dir need not be normalised; time in seconds
```

It replaced the purple galaxy as effect 1. `item.fsh` no longer carries any noise
code of its own — the include is self-contained.

### 15.1 Where it can and cannot be imported

```glsl
#moj_import <anion:slipspace.glsl>
```

works in `core/item` and `core/sky`. It does **not** work in
`core/position_tex_color` — the End sky. That shader also backs
`GUI_TEXTURED_SNIPPET`, which `pipeline/mojang_logo` uses, so it is compiled
before resource packs exist and `#moj_import` is unavailable to it. The existing
comment at the top of this repo's `position_tex_color.fsh` says exactly this and
it is correct; I confirmed the pipeline wiring in the bytecode.

So the file is written to be **paste-able as well as importable**: everything
between the `PASTE BEGIN` / `PASTE END` markers is self-contained, depends on
nothing, and every symbol is `slip_`-prefixed so it will not collide with the
`hash` / `noise` / `fbm` / `rand` already defined in `position_tex_color.fsh`.
I compile-tested that block standalone, not just the import path.

**For the slipspace dimension, prefer `core/sky`** — a datapack dimension whose
effects use the overworld sky renderer goes through `pipeline/sky` →
`core/sky`, which can import normally, and this repo already has a custom
`sky.vsh` producing a corrected direction. Gate on `FogColor` (this pack's
established dimension-selection channel) so the overworld sky is left alone. I
did not wire that up, since it needs your dimension's fog colour to key off.

### 15.2 How it is built

**The wall.** A *band* centred on the plane perpendicular to `SLIP_AXIS`, falling
to black toward both poles. `SLIP_AXIS` is the band's **normal**, not the
direction the gradient runs, so tilting it off vertical tilts the band off
horizontal by the same angle — the default is **12.2°**. The `abs()` is what
makes it symmetric; without it this is a pole-to-pole ramp, light at one end and
dark at the other, which is what it was before.

`SLIP_BAND_WIDTH` sets the half-width in `|dot|` units and `SLIP_FALLOFF` tightens
the core, then low-amplitude FBM mottling keeps it off a clean ramp. Measured
over 60k uniform directions:

| `dot(d, SLIP_AXIS)` | mean luminance |
| --- | --- |
| ±0.0 – 0.1 (on the band) | 0.540 |
| ±0.1 – 0.4 | 0.303 |
| ±0.4 – 0.8 | 0.057 |
| ±0.8 – 1.0 (poles) | 0.006 |

Full range 0.006 → 0.636, symmetric about the band plane.

**The fractures.** Ridged multifractal — `1 - abs(noise)` turns zero crossings
into creases, squaring sharpens them — with the octaves stacked at a
**non-integer lacunarity (2.17)** so they do not line up on the noise lattice.
That is what makes the result read as splintering rather than as a grid. The
input is domain-warped before the ridges are taken, not after: warping the input
bends the creases into splinters, warping the output would only blur them.

One thing worth copying if you write more of these: the raw ridged field rarely
reaches 1.0, because that needs every octave to peak simultaneously. Sampling it
gives mean 0.744, p99 0.934. Applying `pow()` directly to that crushes even the
real ridges, so the field is **rescaled against `SLIP_THRESH` first** and only
then sharpened. Without that step you end up chasing absurd exponents.

**Occasional intervals.** Two gates. A smooth region mask so fractures only open
up in patches, and a temporal phase that varies *smoothly with direction* rather
than per lattice cell — so fronts sweep across the sky instead of popping in on
cell boundaries, with no hard edges anywhere. The phase is wrapped three times
over the sphere, which is what gives several independent fractures firing at
once. Composition is additive: a fracture is an opening onto something brighter,
not paint on the wall.

### 15.3 Constants were measured, not guessed

I cannot see the render, so rather than eyeball the numbers I ported the noise to
NumPy and sampled 40k uniform directions. The first pass was wrong in two ways
and both got fixed:

- The splinter early-out `if (halo > 0.02)` was **taken for 94% of the sky** — it
  was not the optimisation the comment claimed. At the shipped constants and a
  `0.12` threshold it fires for **27%** of the sky and discards **0.65%** of the
  total crack energy, which is a real saving. The comment now records the
  measurement, including how threshold-sensitive it is.
- That same bare threshold was also **drawing visible lines across the sky**, and
  it is the cause of the quadrant banding that showed up in the window. See
  §15.5.
- Cracks covered **23%** of the sky, far too much for "occasional". A sweep over
  `SLIP_THRESH` × `SLIP_SHARP` settled on `0.72` / `6.0`, giving 6.1% of
  directions above a faint crack and 0.53% above a bright one — and that is
  *before* the region and flash gates, which are what make bright fractures rare.

End-to-end at the shipped values: idle luminance peaks at 0.72, peak flash pushes
0.007% of the sky past 1.0 into a blown-out core. Fractures read bright against
the wall without the glow washing the blacks out.

### 15.4 Tuning

Every knob is `#ifndef`-guarded, so an includer overrides any of them by
`#define`-ing it *before* the import. The ones that actually change the look:

| Define | Default | Effect |
| --- | --- | --- |
| `SLIP_THRESH` | `0.72` | where a ridge becomes a crack. **Lower = more cracks**, and it moves fast. |
| `SLIP_SHARP` | `6.0` | filament thinness. Higher = finer, dimmer. |
| `SLIP_HALO` | `1.95` | fat companion field — the glow bleed and the splinter mask. |
| `SLIP_RATE` | `0.09` | fracture cycles per second. |
| `SLIP_IDLE` | `0.18` | how visible the network is when nothing is firing. |
| `SLIP_CRACK_SCALE` | `2.6` | fracture density across the sky. |
| `SLIP_WARP` | `0.55` | 0 = smooth creases, high = jagged splinters. |
| `SLIP_BAND_WIDTH` | `0.78` | band half-width. Larger = the band reaches further toward the poles. |
| `SLIP_SPLINTER_LO` / `_HI` | `0.12` / `0.24` | splinter mask ramp. Must stay a ramp — see §15.5. |
| `SLIP_LIGHT` / `SLIP_DARK` / `SLIP_AXIS` / `SLIP_FALLOFF` | — | the band. `SLIP_AXIS` is its normal. |

The distribution numbers above are solid; the *aesthetic* balance between
"empty grey void" and "too busy" is the part I could not verify without seeing
it. If it reads too sparse, raise `SLIP_IDLE` first and drop `SLIP_THRESH` to
`0.68`; if too busy, push `SLIP_THRESH` to `0.76`.

### 15.5 Two artifacts, and what actually caused them

**Quadrant banding across the window.** Clean lines cutting the aperture into
four. Not a UV or frame problem — the frame reconstruction was fine. Two causes,
both fixed:

1. **A hard threshold on a smooth field draws contours.** The splinter term was
   added at full strength inside `if (halo > 0.12)`, so it jumped from 0 to as
   much as **0.059** across the contour where `halo` crosses `0.12`. Those
   contours are smooth curves; a couple of them crossing an aperture reads
   exactly as quadrant lines. Multiplying by `smoothstep(SLIP_SPLINTER_LO,
   SLIP_SPLINTER_HI, halo)` makes the contribution reach zero precisely where
   the branch switches off. Measured at the contour: the old term peaked at
   `0.0589`, the new one at `0.000122`. The branch is now a pure early-out.

   Worth generalising: any `if (x > k) { result += f(x); }` in a shader is a
   visible edge unless `f` vanishes at `k`. The branch may be an optimisation;
   the discontinuity is never free.

2. **The window was zoomed into a single noise cell.** A 3-block window at 3
   blocks subtends about 54°, which at `SLIP_CRACK_SCALE 2.6` is under one
   lattice cell across. One cell of a ridged field is two or three enormous
   smooth creases — giant bands, not fractures. `slipspace_detail(dir, time,
   detail)` scales the noise domains only; the window passes `WINDOW_DETAIL 5.0`,
   the shell and the open sky pass `1.0`. The band gradient deliberately does not
   scale, so the wall stays consistent between a window and the open sky.

**Shell bouncing with view bobbing.** `GameRenderer.bobView()` applies its head
bob as `PoseStack.translate()` followed by two `mulPose()` rotations, so the bob
**translation ends up in `ModelViewMat`** — `Position` is relative to the
unbobbed camera and never carries it. A shell at a finite radius parallaxes
against that translation: half a block of bob at 24 blocks is about **1.2° of
swing**, which is the visible bounce.

**Both of my first two fixes were built on a wrong premise — see §17. The bob is
not in `ModelViewMat` at all.** What follows is superseded; §17 has the correct
account.

---

## 16. Slipspace revision 2

### 16.1 Band, not a ramp — and the crease it exposed

`SLIP_AXIS` is the band's normal, so the band sits perpendicular to it: tilt the
axis off vertical and the band tilts off horizontal by the same angle.

The profile is built on `h * h`, not `abs(h)`:

```glsl
float hn = h / SLIP_BAND_WIDTH;
float g = pow(clamp(1.0 - hn * hn, 0.0, 1.0), SLIP_FALLOFF);
```

Both are symmetric, but `abs()` has a derivative discontinuity at `h = 0` and
that lands on the single brightest line of the sky. Rendering the shader offline
showed it plainly: a hard crease straight down the middle of the band. `h*h` is
smooth there, and `SLIP_FALLOFF > 1` flattens the approach to zero at the outer
clamp, so the profile is smooth at both ends.

### 16.2 Fractures fade into the band

```glsl
float bandFade = smoothstep(SLIP_CRACK_FADE_LO, SLIP_CRACK_FADE_HI, abs(h));
```

applied to both the crack term and the halo bleed. The wall is intact where it is
lit and only breaks up out in the dark. `SLIP_CRACK_FADE_LO` must stay above
zero — the smoothstep is then flat at `h = 0`, so the kink in `abs()` sits inside
a region already clamped to zero and never shows. That is the same trick as the
splinter mask: put discontinuities where the result is already constant.

### 16.3 Red lightning

`slip_bolts()` reuses the shooting-star segment falloff from the galaxy shader —
clamp the projection onto the bolt axis, measure perpendicular distance,
smoothstep into a line, taper along the length. Two changes:

- **It runs on a tangent plane, not in screen space.** The original was
  deliberately screen-space, which is right for a shooting star but wrong for
  something that has to stay put on the sky. The obvious fix — `atan()` and
  latitude — puts a seam down the back of the sky, and this pack has spent
  enough effort removing seams. A **gnomonic projection about the bolt's own
  centre** has none anywhere in the hemisphere it covers, and the `facing < 0.25`
  cutoff discards the other hemisphere before any work is done.
- **The segment is displaced perpendicular by noise along its length**, which is
  what turns a streak into a bolt.

Each of `SLIP_BOLTS` slots fires once per its own randomised period, with a fast
rise, a ragged decay and a flicker term. Tune with `SLIP_BOLT_LIFE`,
`SLIP_BOLT_W`, `SLIP_BOLT_JAG`, `SLIP_BOLT_AMP`, `SLIP_BOLT_COLOR`.

### 16.4 Shell seams

The shell walls used to sit at `0.1` / `15.9`, so at each cube edge two walls met
with a ~0.6% positional step — a direction discontinuity, and a visible seam from
inside. They now sit just *outside* the cube (`-0.1..0` and `16..16.1`) with their
visible faces landing exactly on `0` and `16`, so adjacent walls terminate on the
same shared edge with nothing between them.

### 16.5 The quadrant lines: not reproduced

I could not reproduce these, and I would rather say so than claim a third fix.

What I did: ported the shader to NumPy and rendered the window path offline —
including the 8-bit ramp texture, nearest sampling, and GPU 2×2-quad derivative
semantics — then compared it against an ideal-ray render. The two are
indistinguishable, and neither shows quadrant lines. The tangent frame came out
uniform across the aperture.

What that ruled out, and what it turned up:

- **Not the 8-bit ramp.** Measured `d(local.x)/dx` against ideal: the error
  distribution is identical with an exact ramp and with the shipped 8-bit one.
- **But the sawtooth was a real hazard.** `d(local)/dx` reaches **−5.5× its true
  value** — a sign flip — on 0.2% of pixels, the aperture's outermost texel ring,
  where the texel step and the `fract` wrap stop cancelling. So the frame now
  differentiates **`texCoord0`** instead, a plain interpolated varying with no
  wrap in it anywhere, and rescales by `RAMP_PX / atlasPx` — exact, needs no
  extra data, and the whole failure mode disappears. `local` is still used for
  the ray origin, where 8-bit quantisation is sub-texel and invisible.
- **Fixed regardless:** the band crease (§16.1) and the shell seams (§16.4), both
  of which are genuinely visible lines and either could plausibly be what was
  being described.

If lines survive all of that, a screenshot would settle it quickly — in
particular whether they are on the flat window or the shell, whether they move
when you turn, and whether they sit on the band or cut across it.

---

## 17. The head bob lives in the projection matrix

This took three attempts. The first two were wrong because I assumed where the
bob was applied instead of checking. `GameRenderer.renderLevel`:

```java
new Matrix4f(cameraRenderState.projectionMatrix)   // copy of the PROJECTION matrix
new PoseStack(); bobHurt(...); bobView(...);
    .mul(poseStack.last().pose())                  // bob multiplied in here
```

So `bobHurt` and `bobView` — a `translate()` and two `mulPose()` rotations — end
up in **`ProjMat`**. `ModelViewMat` is the plain view rotation and contains no
bob at all.

Three consequences, one per failed attempt:

- **Stripping `ModelViewMat`'s translation column does nothing.** There is no
  translation in it to strip. Attempt one was a no-op.
- **The bob translation's angular effect scales as `|t| / |v|`** — it is applied
  to whatever vector you hand the projection. That makes vertex distance the
  only lever, and it made attempt two actively worse:

  | shell vertex length | bob swing |
  | --- | --- |
  | 24 blocks (original) | 1.67° |
  | **1.0 (normalised — attempt two)** | **40.1°** |
  | 4096 blocks (now) | 0.0098° |

  Normalising to a unit direction, which is exactly what "draw it at infinity"
  seemed to call for, multiplied the bounce by twenty-four.
- **The bob rotation cannot be cancelled** and should not be. It is
  indistinguishable from real camera rotation inside the shader, and it is
  applied to the whole world, so the sky turning with it is correct rather than
  an artifact.

The fix is to dilute the translation by pushing the vertex far out, and to stop
depth depending on distance so the huge radius cannot hit the far plane:

```glsl
vec3 v = mat3(modelView) * normalize(dirWorld) * SKYBOX_DISTANCE;  // 4096
vec4 clip = proj * vec4(v, 1.0);
clip.z = 0.0;          // reversed-Z far plane
```

A true point at infinity (`w = 0`) is the exact form of this, but a triangle with
one vertex at `w = 0` while its neighbours are in front of the camera is a
clipping hazard, and 0.0098° is already three orders of magnitude below anything
visible.

**The lesson worth keeping:** "which matrix is this transform in?" is a question
to answer from the bytecode, not from where the transform logically belongs. A
head bob belongs conceptually to the view; Mojang folds it into the projection.

### 17.1 New tuning knobs

Crack pulsing:

| Define | Default | Effect |
| --- | --- | --- |
| `SLIP_RATE` | `0.09` | fracture cycles per second |
| `SLIP_PULSE_SPREAD` | `3.0` | how many independent fronts run across the sky at once |
| `SLIP_PULSE_RISE` | `0.06` | attack, as a fraction of one cycle |
| `SLIP_PULSE_FALL` | `0.45` | decay end, as a fraction of one cycle |
| `SLIP_PULSE_BASE` | `0.45` | brightness of a lit region between flashes |
| `SLIP_PULSE_GAIN` | `1.7` | extra brightness at the peak |

Lightning:

| Define | Default | Effect |
| --- | --- | --- |
| `SLIP_BOLTS` | `3` | strike slots tracked at once |
| `SLIP_BOLT_PERIOD` | `4.0` | minimum seconds between one slot's strikes |
| `SLIP_BOLT_PERIOD_VAR` | `10.0` | random extra on top |
| `SLIP_BOLT_LIFE` | `0.55` | seconds a strike lasts |
| `SLIP_BOLT_FLICKER` | `40.0` | strobe rate during a strike |
| `SLIP_BOLT_W` / `_LEN` / `_JAG` / `_AMP` / `_COLOR` | — | shape and colour |

Mean interval between strikes anywhere in the sky is roughly
`(SLIP_BOLT_PERIOD + SLIP_BOLT_PERIOD_VAR / 2) / SLIP_BOLTS` — about 3 seconds at
the defaults. Halve `SLIP_BOLT_PERIOD_VAR` to roughly double the rate.

### 17.3 Making the band wavy

The band was a perfect great circle: `dot(d, SLIP_AXIS)` fed straight into the
profile. Two noise fields now break that up.

```glsl
float wave  = slip_fbm(q * SLIP_WAVE_SCALE + vec3(41.0, 13.0, 17.0), SLIP_WAVE_OCT);
float width = SLIP_BAND_WIDTH
            * (1.0 + slip_fbm(q * SLIP_WAVE_SCALE * 0.55 + vec3(7.0, 23.0, 3.0), 2)
                     * SLIP_WIDTH_VAR);

float h  = dot(d, SLIP_AXIS) + wave * SLIP_WAVE;
float hn = h / max(width, 0.05);
float g  = pow(clamp(1.0 - hn * hn, 0.0, 1.0), SLIP_FALLOFF);
```

The distinction that matters: **`wave` displaces the band coordinate, it does not
scale the result.** Warping the input bends the centre line into a meander.
Multiplying `g` by noise afterwards would only make the band brighter and dimmer
in patches — the band would stay dead straight and just look blotchy. Same
principle as the domain warp feeding the fractures.

`width` is a separate field so the band swells and pinches along its length
rather than holding one thickness. Both sample `q` directly, **not** `q * detail`
— the band is deliberately detail-independent so a flat window and the open sky
agree on where it is; scaling the meander with detail would put it somewhere
different in each.

`h` is the warped coordinate, so `bandFade` — the fracture fade near the band —
follows the meander automatically. No extra work needed there.

| Define | Default | Effect |
| --- | --- | --- |
| `SLIP_WAVE` | `0.22` | centre-line displacement, same units as `SLIP_BAND_WIDTH`. `0.0` restores the flat band exactly. At `0.22` against a width of `0.58` the line swings about a third of the half-width. |
| `SLIP_WAVE_SCALE` | `1.5` | meander frequency. Low = long lazy curves, high = tight switchbacks. |
| `SLIP_WAVE_OCT` | `3` | detail. `1` is a clean sine-like curve; `4`+ gets ragged and cloud-edged. |
| `SLIP_WIDTH_VAR` | `0.45` | swell/pinch as a fraction of the half-width. |

Rendered sweep: `0.22 / 1.5 / 3 / 0.45` gives a clear meander with visible
pinching while the band still reads as one continuous ribbon.
`0.35 / 2.4 / 4 / 0.6` turns it turbulent and cloud-like — worth trying if you
want it less like a ribbon and more like a rift.

### 17.4 Matching the window to the sky

Two changes so a window is a genuine porthole onto the same slipspace the sky
and shell show.

**Scale.** `WINDOW_DETAIL` is back to `1.0`. It had been `5.0`, which multiplied
the window's noise domain by five and made its fractures five times finer than
the sky's — the window and the dimension sky were showing the same shader at
different scales. The `5.0` was over-correction for a problem that turned out not
to exist: rendering the window offline at native scale shows a perfectly
well-formed fracture field, and the banding it was meant to fix was the splinter
mask's threshold contour (§16.5).

**Orientation.** `runEffect` now takes both rays:

```glsl
vec3 runEffect(vec3 ro, vec3 rd, vec3 rdW, vec2 lp, float t, float detail)
```

`rd` is the aperture-local ray, `rdW` the world one; they are the same vector on
the shell and differ by the window's orientation on a flat window. Slipspace now
takes `rdW`, so a window shows the same patch of sky you would see looking that
way, and turning the window reframes it rather than swinging the view. The
marched effects keep `rd`, since their geometry is defined relative to the
aperture and is meant to rotate with it.

### 17.5 Splinter mask orientation

`smoothstep(SLIP_SPLINTER_LO, SLIP_SPLINTER_HI, halo)` only behaves as named
while `LO < HI`. Reversed, the ramp runs backwards and three things happen at
once: splinters cluster *away* from the main fractures instead of along them,
the `if (splinter > 0.0)` early-out fires across nearly the whole sky, and the
mask no longer reaches zero where the branch cuts off — which reintroduces the
discontinuity contour that caused the original banding.

Current values are `LO 0.04` / `HI 0.9`, a much wider ramp than the original
`0.12` / `0.24`:

| halo | `0.04 / 0.9` | `0.12 / 0.24` |
| --- | --- | --- |
| 0.12 | 0.024 | 0.000 |
| 0.30 | 0.219 | 1.000 |
| 0.60 | 0.720 | 1.000 |
| 0.90 | 1.000 | 1.000 |

Correct orientation, but splinters only reach full strength on the very
strongest fractures, so the fine detail is sparser. Narrow the range — keeping
`LO < HI` — to bring it back.

---

## 18. Preview shells

Two `item_display` shells that let you stand inside a sky and iterate on it
without building the dimension.

### 18.1 What changed to make this possible

The galaxy had been deleted from `item.fsh` when slipspace replaced it, so there
was nothing to preview. It is now `assets/anion/shaders/include/galaxy.glsl` —
same extraction treatment as slipspace: `gal_`-prefixed symbols, `#ifndef`
knobs, `PASTE BEGIN`/`PASTE END` markers, and no uniform dependencies at all.

That last part is why `streakUV` is a parameter instead of being read from
`Globals`. Zero uniform dependencies is what lets the block be pasted into
`core/position_tex_color`, which cannot `#moj_import` because
`pipeline/mojang_logo` compiles it before resource packs load.

The effect dispatch went from four slots to eight, so more skies can be added
without renumbering:

| Slot | Red byte | Effect | `dyed_color` |
| --- | --- | --- | --- |
| 0 | 0–31 | frame debug | `1054752` (`#101820`) |
| 1 | 32–63 | **slipspace** | `2646271` (`#2860FF`) |
| 2 | 64–95 | **galaxy** | `5284095` (`#50A0FF`) |
| 3 | 96–127 | marched shapes | `7405456` (`#70FF90`) |
| 4 | 128–159 | tunnel | `9502656` (`#90FFC0`) |
| 5–7 | 160–255 | spare — falls through to slipspace | |

Both skies take the **world** ray, so a shell and a window agree with each other
and with the dimension sky.

### 18.2 Setup

1. **Reload.** `F3` + `T`. The shaders changed; the models did not.

2. **Summon the two shells, far apart and tagged.** 256 blocks is enough that
   the other one never subtends a meaningful part of your view:

```
/summon item_display ~ ~ ~ {Tags:["skyprev","prev_slip"],item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:sky_sphere","minecraft:dyed_color":2646271}},item_display:"fixed",billboard:"fixed",view_range:16.0,transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[24f,24f,24f],right_rotation:[0f,0f,0f,1f]}}
```

```
/summon item_display ~256 ~ ~ {Tags:["skyprev","prev_galaxy"],item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:sky_sphere","minecraft:dyed_color":5284095}},item_display:"fixed",billboard:"fixed",view_range:16.0,transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[24f,24f,24f],right_rotation:[0f,0f,0f,1f]}}
```

3. **Step inside.** You are already in the slipspace one. `/tp @s ~256 ~ ~` for
   the galaxy.

4. **Clean up.** `/kill @e[tag=skyprev]`.

### 18.3 Things that will confuse a preview if you do not know them

- **Do not let the two overlap.** Both shells draw at the reversed-Z far plane,
  and the depth test is `GEQUAL`, so `0 >= 0` passes and whichever draws *last*
  wins. Two shells in view means the far one paints a cone of its sky inside the
  near one's. Keep them apart, or work one at a time with
  `/kill @e[tag=prev_galaxy]`.
- **Clouds and weather draw after the main pass**, so they render *over* the
  shell rather than being replaced by it. Turn clouds off in video settings
  while previewing, and do not preview in rain.
- **The shell no longer occludes terrain** — it is at infinity now, so it fills
  only what would otherwise be sky. Preview somewhere with a clear horizon.
- **Scale only sets the walk-in boundary.** It has nothing to do with the
  apparent size of the sky, which is fixed by direction. `24f` gives a 24-block
  bubble to stand in.

### 18.4 Optional: make the End sky use the shared galaxy

Right now `position_tex_color.fsh` still carries its own inline copy, so tweaking
`galaxy.glsl` will not change the End and the preview shell can drift away from
what the dimension actually renders. To make the include the single source of
truth:

1. In `position_tex_color.fsh`, delete everything from `///// HELPER FUNCTIONS`
   down to the end of `renderStreak`.
2. Paste the `PASTE BEGIN` → `PASTE END` block from `galaxy.glsl` in its place.
   The `gal_` prefixes mean nothing collides even if you leave the old helpers
   behind while testing.
3. Replace the galaxy body inside the `isEndSky` branch with:

```glsl
vec2 streakUV = (2.0 * gl_FragCoord.xy - ScreenSize) / ScreenSize.y;
fragColor = vec4(galaxy(Pos, GameTime * 1200.0, streakUV), 1.0);
```

The `#moj_import` route is not available there — that file backs
`pipeline/mojang_logo` and is compiled before resource packs exist.

### 18.5 Two shells: behind the world, and clearing it

| Model | Depth written | Behaviour |
| --- | --- | --- |
| `anion:sky_sphere` | reversed-Z far (`0.0`) | Terrain occludes it; it fills only what would otherwise be sky. A skybox. |
| `anion:sky_sphere_over` | the bubble wall's own distance | Everything **beyond** the wall is replaced by sky. Everything **inside** it is untouched. |

Same geometry, same shading, same bob-proof transform. Only the depth differs.

**The radius needs no knob.** `length(Position)` is the distance to the shell's
own surface in that direction, so the wall lands exactly on the model and tracks
the display entity's `scale` automatically — the visual boundary and the
walk-out boundary are the same surface by construction.

The model is a cube, so the cleared volume is cube-shaped. At `scale 24` that is
12 blocks of headroom at a face centre, 17 at an edge, 20.8 at a corner. Vanilla
block models only allow axis-aligned boxes, so a genuinely spherical clear zone
is not something the model can express — if it matters, clamp the radius in the
vertex shader instead.

**Why two projections.** `skybox_clip_at` runs the projection twice and splices
the results, because neither one can do both jobs:

```glsl
vec4 clip = proj * vec4(v * SKYBOX_DISTANCE, 1.0);   // x, y, w  - bob-proof
vec4 near = proj * vec4(v * radius, 1.0);            // z        - the bubble wall
clip.z = (near.z / max(near.w, 1e-6)) * clip.w;
```

The bob is a translation living in the projection matrix, and its angular effect
scales as `|t| / |v|`, so only a very long vector dilutes it (§17). But depth at
4096 blocks is meaningless. Taking `z/w` from the short vector and rescaling by
the long one's `w` gets both: drawn where the bob-proof projection puts it, at
the depth of the wall.

The bob does still jitter the depth, by `|t| / radius`:

| radius | jitter |
| --- | --- |
| 12 | 5.8% |
| 24 | 2.9% |
| 48 | 1.5% |

That is a constant ~0.7 blocks of movement in the cut-off plane regardless of
radius, which takes terrain sitting exactly on the boundary to notice.

**This composes correctly with the rest of the frame**, which the earlier
near-plane version did not. Depth is still written, so anything drawn later is
tested against the wall: nearer fragments pass, farther ones fail. Clouds
disappear (they are far), the held item stays (it is near), particles behave by
distance. No special cases.

### 18.6 Three shells, and the teleporter pairing

| Model | Faces | Visible from | Draws at | Effect |
| --- | --- | --- | --- | --- |
| `anion:sky_sphere` | inward | both | far plane | Ordinary skybox. Terrain occludes it. |
| `anion:sky_sphere_over` | inward | both | near wall | From inside: world beyond the wall replaced by sky, interior kept. |
| `anion:sky_sphere_hull` | **outward** | outside only | near wall | From outside: opaque, hides the interior. From inside: gone. |

**The hull needed no shader change.** Item pipelines backface-cull, and that
alone decides which side of the bubble you can see:

- **Inward** faces — from inside, the near wall faces you and is drawn. From
  outside, the near wall points away and is culled, so you see the *far* wall
  instead. That is precisely why `sky_sphere_over` lets you see into the bubble
  from outside.
- **Outward** faces — the exact mirror. From outside you get the near wall, at
  the near wall's depth, which hides everything behind it. From inside every
  face is backfacing and the shell disappears entirely.

Verified rather than assumed: dotting each declared face's normal against the
vector from the model centre gives 96/96 inward for `sky_sphere` and
`sky_sphere_over`, 96/96 outward for `sky_sphere_hull`. All three put their
visible face planes at exactly `0.0` and `16.0`, so the three surfaces are
coincident and there is no gap or overlap at the boundary.

The radial vertex remap is a per-vertex positive scale, which preserves triangle
orientation about the origin, so culling behaves the same after `normalize()` as
before it.

`sky_sphere_hull` shares `sky_sphere_over`'s texture signature deliberately — the
shader treats them identically, only the winding differs.

#### Pairing them

Summon `sky_sphere_hull` and `sky_sphere_over` at the **same position, same
scale, same `dyed_color`**. Since their surfaces are coincident, exactly one is
ever drawn:

- **Outside:** the hull is opaque. The bubble is a solid ball of slipspace and
  the interior is hidden.
- **Inside:** the hull culls away, `_over` takes over, and you see the local
  terrain with slipspace replacing everything beyond the wall.
- **Crossing:** the handover happens exactly at the wall, because both shells
  put their faces on the same plane.

```
/summon item_display ~ ~ ~ {Tags:["tp","tp_hull"],item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:sky_sphere_hull","minecraft:dyed_color":2646271}},item_display:"fixed",billboard:"fixed",view_range:64.0,transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[24f,24f,24f],right_rotation:[0f,0f,0f,1f]}}
```

```
/summon item_display ~ ~ ~ {Tags:["tp","tp_in"],item:{id:"minecraft:paper",count:1,components:{"minecraft:item_model":"anion:sky_sphere_over","minecraft:dyed_color":2646271}},item_display:"fixed",billboard:"fixed",view_range:64.0,transformation:{translation:[0f,0f,0f],left_rotation:[0f,0f,0f,1f],scale:[24f,24f,24f],right_rotation:[0f,0f,0f,1f]}}
```

`/kill @e[tag=tp]` removes both.

Four things that matter for a teleporter:

- **Both entities need the same `dyed_color`**, or the sky changes as you cross.
- **Raise `view_range`.** It defaults to `1.0` and gates distance rendering. The
  culling box does not matter — `Display` sets `noCulling` whenever `width` and
  `height` are both `0`, which is the default (§14.6).
- **The scale is the boundary.** At `scale 24` the wall is 12 blocks out at a
  face centre and 20.8 at a corner, since the model is a cube. Fire the teleport
  well inside that, not at the wall, or a player skimming the corner will trigger
  it while still able to see out.
- **The hull covers the view completely only from outside.** If you want the
  screen fully covered at the moment of the teleport, that is the `_over` shell's
  job and it only holds while the player is inside — so teleport from inside.

---

## 19. Signature collisions with ordinary items

A bad regression, and worth recording because the failure mode was so much worse
than the mistake suggests.

### 19.1 What happened

`item.vsh` decided whether a vertex belonged to a sky shell by testing the
**blue channel alone**:

```glsl
float sig = textureLod(Sampler0, UV0, 0.0).b;
bool shellBehind = abs(sig - SPHERE_MAGIC) < SPHERE_TOL;   // b in [0.313, 0.353]
```

The fragment shader had an `r < 0.06 && g < 0.06` guard. The vertex shader did
not. So any ordinary block whose corner texel happened to have blue in one of
those two windows had that vertex replaced with `normalize(Position)` and flung
onto the unit sphere. Move one corner of a quad and the texture stretches across
the diagonal; move all four and the face vanishes. Dropped items and the held
item both go through `core/item`, so both were affected.

Measured over every block and item texture in the 26.2 jar — 2065 textures,
739,840 texels:

| Test | Matching texels | Textures affected |
| --- | --- | --- |
| shell, blue only *(shipped)* | 60,780 — **8.2%** | **1383 of 2065** |
| shell, `+ r,g < 0.06 & a > 0.99` | **0** | 0 |
| window, blue only *(shipped)* | 12,091 — 1.6% | — |
| window, `+ alpha magic` | **0** | 0 |

### 19.2 The window needed a different fix

The shells are `(0, 0, magic, 255)`, so red and green are free to act as guards.
The window ramp spends red and green on local coordinates — they cover the full
range by design — so blue was genuinely its only signature, and blue alone paints
slipspace over 1.6% of ordinary item pixels.

Alpha is unused on that path, so it now carries a second independent 8-bit
constraint: `window_ramp.png` is authored with **alpha 200**, far from both 255
and 0, which are the only values ordinary item textures use. Alpha moved out of
the shared `perspective` precondition and into each signature, since the shells
and the window now expect different values in it.

### 19.3 Also hardened

Shell model UVs are inset from `[0,0,16,16]` to `[1,1,15,15]`. The vertex fetch
samples at a quad *corner*, and with full-sprite UVs those corners sit exactly on
the sprite boundary in the atlas, where NEAREST rounding can land on the
neighbouring sprite. The signature texture is a flat colour, so insetting costs
nothing and makes the fetch land a texel inside.

### 19.4 The general lesson

**A signature test in a vertex shader needs to be stricter than the same test in
a fragment shader, not looser.** A fragment-side false positive is a wrong-coloured
pixel. A vertex-side false positive is corrupted geometry that can cover the
screen. This one had the guard on the cheap side and not the expensive one.

Worth checking whenever a magic value is added: run it against the actual texture
set rather than reasoning about how unlikely a collision seems. 8.2% is not a
number I would have guessed.
