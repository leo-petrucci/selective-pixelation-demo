@tool
extends CompositorEffect
class_name MainViewportComposite

@export var shared_depth: SharedDepthBuffer

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID

const COMPUTE_SRC := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D main_color;

layout(set = 1, binding = 0) uniform sampler2D main_depth_sampler;
layout(set = 1, binding = 1) uniform sampler2D sub_color_sampler;
layout(set = 1, binding = 2) uniform sampler2D sub_depth_sampler;

layout(push_constant, std430) uniform Params {
		vec2 resolution;
		vec2 sub_resolution;
		mat4 inv_projection;
} params;

float linearize_depth(vec2 uv, float depth_sample) {
		vec4 clip = vec4(uv * 2.0 - 1.0, depth_sample, 1.0);
		vec4 view = params.inv_projection * clip;
		view /= view.w;
		return -view.z;
}

float linearize_depth_new(float raw_depth, vec2 uv) {
		vec4 clip = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
		vec4 view = params.inv_projection * clip;
		view /= view.w;
		return -view.z;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 main_size = ivec2(params.resolution);
    if (pixel.x >= main_size.x || pixel.y >= main_size.y) {
        return;
    }

    vec2 uv = (vec2(pixel) + 0.5) / params.resolution;

    float depth_raw = texture(main_depth_sampler, uv).r;
    float main_depth = linearize_depth_new(depth_raw, uv);
    float sub_depth = texture(sub_depth_sampler, uv).r;

    // Visualize depth: red = main depth (scaled), green = sub depth (scaled)
    float main_vis = clamp(main_depth / 20.0, 0.0, 1.0);
    float sub_vis = clamp(sub_depth / 20.0, 0.0, 1.0);

    imageStore(main_color, pixel, vec4(main_vis, sub_vis, 0.0, 1.0));
}

void mainold() {
		ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
		ivec2 main_size = ivec2(params.resolution);
		if (pixel.x >= main_size.x || pixel.y >= main_size.y) {
				return;
		}

		vec2 main_uv = (vec2(pixel) + 0.5) / params.resolution;
		vec2 sub_uv = main_uv * (params.resolution / params.sub_resolution);

		vec4 base_color = imageLoad(main_color, pixel);
		float main_depth_raw = texture(main_depth_sampler, main_uv).r;
		float main_depth = linearize_depth(main_uv, main_depth_raw);

		vec4 sub_color = texture(sub_color_sampler, sub_uv);
		float sub_depth = texture(sub_depth_sampler, sub_uv).r;

		// If the sub viewport depth is zero, treat it as empty.
		if (sub_depth > 0.0 && sub_depth < main_depth) {
				imageStore(main_color, pixel, vec4(sub_color.rgb, base_color.a));
		} else {
				imageStore(main_color, pixel, base_color);
		}
}
""";

func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		rd = RenderingServer.get_rendering_device()
		_build_pipeline()

func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
				if shader.is_valid():
						rd.free_rid(shader)
				if pipeline.is_valid():
						rd.free_rid(pipeline)
				if sampler.is_valid():
						rd.free_rid(sampler)

func _build_pipeline() -> void:
		if shader.is_valid():
				return

		var src := RDShaderSource.new()
		src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		src.source_compute = COMPUTE_SRC
		var spirv := rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
				push_error(spirv.compile_error_compute)
				return

		shader = rd.shader_create_from_spirv(spirv)
		pipeline = rd.compute_pipeline_create(shader)

		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler = rd.sampler_create(sampler_state)

func _render_callback(p_type: int, p_render_data: RenderData) -> void:
		if p_type != effect_callback_type:
				return
		if not shared_depth.texture_rid.is_valid():
				return
		if not shader.is_valid() or not pipeline.is_valid():
				return

		var rsb: RenderSceneBuffers = p_render_data.get_render_scene_buffers()
		if rsb == null:
				return

		var main_size: Vector2i = rsb.get_internal_size()
		if main_size.x <= 0 or main_size.y <= 0:
				return

		var scene_data := p_render_data.get_render_scene_data()
		var inv_projection := scene_data.get_cam_projection().inverse()

		var groups_x := int((main_size.x - 1) / 8) + 1
		var groups_y := int((main_size.y - 1) / 8) + 1

		var push := PackedFloat32Array()
		push.append(float(main_size.x))
		push.append(float(main_size.y))
		push.append(float(shared_depth.size.x))
		push.append(float(shared_depth.size.y))
		for row in range(4):
				for col in range(4):
						push.append(inv_projection[row][col])

		var sub_color_rid := shared_depth.color_texture_rid
		if not sub_color_rid.is_valid():
				print("Invalid sub color RID")
				return

		var sub_depth_rid := shared_depth.texture_rid
		if not sub_depth_rid.is_valid():
				print("Invalid sub depth RID")
				return

		var view_count: int = rsb.get_view_count()
		for view in range(view_count):
				var main_depth_rid: RID = rsb.get_depth_layer(view)
				if not main_depth_rid.is_valid():
						continue

				var main_color_image: RID = rsb.get_color_layer(view)
				if not main_color_image.is_valid():
						continue

				var u_color := RDUniform.new()
				u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u_color.binding = 0
				u_color.add_id(main_color_image)
				var set0 := UniformSetCacheRD.get_cache(shader, 0, [u_color])

				var u_main_depth := RDUniform.new()
				u_main_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u_main_depth.binding = 0
				u_main_depth.add_id(sampler)
				u_main_depth.add_id(main_depth_rid)

				var u_sub_color := RDUniform.new()
				u_sub_color.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u_sub_color.binding = 1
				u_sub_color.add_id(sampler)
				u_sub_color.add_id(sub_color_rid)

				var u_sub_depth := RDUniform.new()
				u_sub_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u_sub_depth.binding = 2
				u_sub_depth.add_id(sampler)
				u_sub_depth.add_id(shared_depth.texture_rid)

				var set1 := UniformSetCacheRD.get_cache(shader, 1, [u_main_depth, u_sub_color, u_sub_depth])

				var cl := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(cl, pipeline)
				rd.compute_list_bind_uniform_set(cl, set0, 0)
				rd.compute_list_bind_uniform_set(cl, set1, 1)
				rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
				rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
				rd.compute_list_end()
