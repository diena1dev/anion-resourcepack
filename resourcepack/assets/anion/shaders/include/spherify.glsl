#version 330

//==========================================================================//
// spherify.glsl
//
// Remaps incoming vertices onto a sphere, so an ordinary cube-shell item model
// can act as a localized skybox the player walks into.
//
//
// WHY THERE IS NO "sphere around the entity" FUNCTION
//
// The obvious signature would be spherify(vertex, entityOrigin, radius). It
// cannot be written for item or entity shaders, because the entity origin is
// not reachable from a vertex shader in 26.2:
//
//   * The pose is baked into the vertex data CPU-side. entity.vsh and item.vsh
//     both feed Position straight into fog_spherical_distance(), which is
//     length(), so Position is already camera-relative world space and carries
//     no separate model origin.
//   * ModelViewMat is therefore just the camera view matrix. There is no
//     per-entity translation left in it to extract.
//   * DynamicTransforms.ModelOffset exists, but only the four-argument
//     DynamicUniforms.writeTransform overload sets it, and item draws do not
//     use that overload. It is zero here.
//   * The vertex attributes are Position, Color, UV0, UV1, UV2 and Normal.
//     Color and the UVs are per-face constants you author, and a vanilla block
//     model cannot give a quad arbitrary per-vertex UVs (a face gets one
//     axis-aligned rect), so there is no channel wide enough to smuggle an
//     origin through.
//
// The view-anchored mapping below sidesteps this completely, and for a skybox
// it is also the more correct choice - see the note on spherify_view.
//==========================================================================//


// Project a camera-relative vertex onto a sphere of the given radius centred on
// the camera.
//
// This is the one to use for a walk-in skybox. Every vertex lands at exactly
// `radius` from the eye, which is what a skybox is; the shell's original shape
// only decides *which directions* are covered:
//
//   * camera inside the shell  -> the shell covers every direction, so you get
//                                 a full sphere of sky around you.
//   * camera outside the shell -> it covers the solid angle the object
//                                 subtends, so you see a patch of that sky
//                                 sitting where the object is, growing to fill
//                                 your view as you walk in.
//
// The transition happens exactly at the model's real surface, so the object
// stays localized in the world even though the projection is view-anchored.
//
// Because magnitude is discarded, the shell's wall thickness and tessellation
// do not affect the result at all - only the set of directions it spans.
vec3 spherify_view(vec3 posRel, float radius) {
    return normalize(posRel) * radius;
}

// Same, but with a soft floor on the radius so the shell never crosses in
// front of nearby geometry. Useful when the sky radius is small enough that
// the player can get closer to the shell than `radius`.
vec3 spherify_view_min(vec3 posRel, float radius, float minRadius) {
    return normalize(posRel) * max(radius, minRadius);
}

// Draw a direction as a distant point, with depth pinned to the far plane.
// This is what makes a shell behave as an actual skybox.
//
//
// WHERE THE HEAD BOB ACTUALLY LIVES
//
// Not in ModelViewMat. GameRenderer.renderLevel builds it like this:
//
//     new Matrix4f(cameraRenderState.projectionMatrix)
//         .mul(poseStack.last().pose())      // <- bobHurt + bobView applied here
//
// so the bob translation and its two rotations are multiplied into the
// **projection matrix**. ModelViewMat is the plain view rotation.
//
// Three consequences, each of which cost me an attempt:
//
//   * Stripping ModelViewMat's translation column does nothing at all. There is
//     no translation in it to strip.
//   * The bob translation is applied to whatever vector you hand the projection,
//     so its angular effect scales as |t| / |v|. At the shell's old 24-block
//     radius that was 0.5/24, about 1.2 degrees of swing. Reducing the vertex to
//     a *unit* direction made it 0.5/1 - roughly 26 degrees. Normalising made
//     the bounce twenty times worse, not better.
//   * You cannot cancel the bob rotation. It is indistinguishable from real
//     camera rotation inside the shader, and it applies to the whole world
//     anyway, so the sky rotating with it is correct - that part is not an
//     artifact.
//
// So: push the vertex far enough out that the residual translation is diluted
// below perception. At 4096 blocks a 0.7-block bob is 1.7e-4 rad, under a
// hundredth of a degree. Forcing clip.z to the reversed-Z far value keeps the
// shell behind everything and, importantly, stops the huge radius running into
// the far plane - depth no longer depends on distance at all.
//
// A true point at infinity (w = 0) is the exact version of this, but a triangle
// with one vertex at w = 0 while its neighbours are in front of the camera is a
// clipping hazard, and the dilution is already three orders of magnitude below
// anything visible.
//
// Pass ProjMat and ModelViewMat in rather than reading them, so this file stays
// independent of which uniform blocks the including shader has.
#ifndef SKYBOX_DISTANCE
#define SKYBOX_DISTANCE 4096.0
#endif

vec4 skybox_clip(vec3 dirWorld, mat4 modelView, mat4 proj) {
    vec3 v = mat3(modelView) * normalize(dirWorld) * SKYBOX_DISTANCE;
    vec4 clip = proj * vec4(v, 1.0);
    clip.z = 0.0;          // reversed-Z: 0 is the far plane, 1 is the near plane
    return clip;
}

// As above, but with the depth of a real surface at `radius` instead of the far
// plane. Under GEQUAL that hides everything *beyond* the radius while leaving
// everything nearer than it alone - the world outside the bubble is replaced by
// sky, the world inside it is untouched.
//
// The two projections are doing different jobs and neither can do both:
//
//   * the far one supplies x, y and w. The head bob is a translation living in
//     the projection matrix, and its angular effect scales as |t| / |v|, so
//     only a very long vector dilutes it away. See skybox_clip above.
//   * the radius one supplies depth, which is the whole point of the mode and
//     is meaningless at 4096 blocks.
//
// Taking z/w from the second and rescaling by the first's w splices them: the
// shell is drawn where the bob-proof projection puts it, at the depth of the
// bubble wall. The bob does still jitter the depth by |t| / radius - about 3%
// at 24 blocks - but that only moves the cut-off by a few centimetres, which
// takes terrain sitting exactly on the boundary to notice.
//
// Depth is still written, so this composes correctly with everything drawn
// later in the frame: nearer fragments pass, farther ones fail. Clouds go away
// (they are far), the held item stays (it is near).
vec4 skybox_clip_at(vec3 dirWorld, float radius, mat4 modelView, mat4 proj) {
    vec3 v = mat3(modelView) * normalize(dirWorld);

    vec4 clip = proj * vec4(v * SKYBOX_DISTANCE, 1.0);
    vec4 near = proj * vec4(v * radius, 1.0);

    // Guard the divide: behind the camera both w values go non-positive and the
    // vertex is clipped anyway, but a NaN here would take the whole triangle
    // with it.
    clip.z = (near.z / max(near.w, 1e-6)) * clip.w;
    return clip;
}

// Point reflection through the camera. det(-I) = -1 in three dimensions, so the
// screen-space winding of every triangle flips and backface culling reveals the
// opposite side of the shell.
//
// Use this when the model has ordinary outward-facing faces and you cannot or
// do not want to re-author them inward. Note what actually happens: negating
// all three vertices leaves the geometric normal unchanged - the two edge
// vectors both flip, and cross(-a, -b) == cross(a, b) - while moving the face
// to the antipode. A face that pointed away from the centre now sits opposite
// and points toward it.
//
// Only sound while the camera is inside a closed shell; from outside it puts
// the sky on the wrong side of you.
vec3 spherify_view_flip(vec3 posRel, float radius) {
    return -normalize(posRel) * radius;
}

// Explicit-centre variant, for the shaders that *do* know an origin:
// core/block gets one from DynamicTransforms.ModelOffset, core/terrain from
// ChunkPosition. Gives a genuinely world-anchored sphere.
vec3 spherify_about(vec3 posRel, vec3 center, float radius) {
    return center + normalize(posRel - center) * radius;
}

// Distortion-reducing cube-to-sphere map, for the case where you hold real
// model-space coordinates normalised to [-1, 1] on each axis.
//
// Plain normalize() bunches a uniform cube grid up near the face centres and
// stretches it at the corners. This spreads it far more evenly, which matters
// if the shell's tessellation is visible - for example if you texture it rather
// than shading it procedurally from the view ray.
vec3 cube_to_sphere(vec3 c) {
    vec3 c2 = c * c;
    return vec3(
        c.x * sqrt(max(0.0, 1.0 - c2.y * 0.5 - c2.z * 0.5 + c2.y * c2.z / 3.0)),
        c.y * sqrt(max(0.0, 1.0 - c2.z * 0.5 - c2.x * 0.5 + c2.z * c2.x / 3.0)),
        c.z * sqrt(max(0.0, 1.0 - c2.x * 0.5 - c2.y * 0.5 + c2.x * c2.y / 3.0))
    );
}
