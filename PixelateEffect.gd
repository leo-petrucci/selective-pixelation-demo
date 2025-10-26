# res://effects/PixelateEffect.gd
@tool
extends CompositorEffect
class_name PixelateEffect

# --- User knobs ---
@export var block_size_px := Vector2i(4, 4) # (x, y) pixel block size

# Internal state
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var shader_is_ready := false

# Compute shader template: we’ll snap to a coarse UV grid and sample the color there.
const COMPUTE_SRC := """
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
    vec2 raster_size;      // width, height of the color buffer
    vec2 block_size;       // size of the pixelation block in pixels
} params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(params.raster_size);
    if (uv.x >= size.x || uv.y >= size.y) return;

    // Snap this pixel's UV to the top-left of a block.
    ivec2 snapped = ivec2( (uv / ivec2(params.block_size)) * ivec2(params.block_size) );

    // Read once from the snapped coord to get that block's color.
    vec4 color = imageLoad(color_image, snapped);

    // Write the same color back to this pixel.
    imageStore(color_image, uv, color);
}
""";

func _init():
    # Run this effect after transparent so it also pixelates previous effects (e.g., outlines).
    effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
    rd = RenderingServer.get_rendering_device()
    _build_pipeline()

func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if shader.is_valid():
            rd.free_rid(shader)

func _build_pipeline():
    if not rd: return
    var src := RDShaderSource.new()
    src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    src.source_compute = COMPUTE_SRC
    var spirv := rd.shader_compile_spirv_from_source(src)
    if spirv.compile_error_compute != "":
        push_error(spirv.compile_error_compute)
        return
    shader = rd.shader_create_from_spirv(spirv)
    if not shader.is_valid(): return
    pipeline = rd.compute_pipeline_create(shader)
    shader_is_ready = pipeline.is_valid()

func _render_callback(p_effect_callback_type, p_render_data):
    if not shader_is_ready: return
    if p_effect_callback_type != effect_callback_type: return

    var rsb: RenderSceneBuffers = p_render_data.get_render_scene_buffers()
    if rsb == null: return

    # Internal (3D) render size — this is the buffer we’re modifying.
    var size: Vector2i = rsb.get_internal_size()
    if size.x <= 0 or size.y <= 0: return

    # Dispatch groups (ceil division by local_size = 16).
    var x_groups := int((size.x - 1) / 16) + 1
    var y_groups := int((size.y - 1) / 16) + 1

    # Push constants: raster size and block size (in pixels).
    var push := PackedFloat32Array()
    push.push_back(float(size.x))
    push.push_back(float(size.y))
    push.push_back(float(max(1, block_size_px.x)))
    push.push_back(float(max(1, block_size_px.y)))

    # For stereo/multiview safety:
    var view_count: int = rsb.get_view_count()
    for view in range(view_count):
        var color_image: RID = rsb.get_color_layer(view) # read/write image
        var u := RDUniform.new()
        u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
        u.binding = 0
        u.add_id(color_image)

        var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [u])

        var cl := rd.compute_list_begin()
        rd.compute_list_bind_compute_pipeline(cl, pipeline)
        rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
        rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
        rd.compute_list_dispatch(cl, x_groups, y_groups, 1)
        rd.compute_list_end()
