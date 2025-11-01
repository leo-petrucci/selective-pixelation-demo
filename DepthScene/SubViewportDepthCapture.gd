@tool
extends CompositorEffect
class_name SubViewportDepthCapture

@export var shared_buffer: SharedDepthBuffer

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID

const COMPUTE_SRC := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_sampler;
layout(r32f,    set = 0, binding = 1) uniform writeonly image2D depth_write;
layout(set = 0, binding = 2) uniform sampler2D color_sampler;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D color_write;

layout(push_constant, std430) uniform Params {
		vec2 resolution;
		vec2 _pad0;
		mat4 inv_projection;
} params;

float linearize_depth(float raw_depth, vec2 uv) {
		vec4 clip = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
		vec4 view = params.inv_projection * clip;
		view /= view.w;
		return -view.z;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(params.resolution);
    if (pixel.x >= size.x || pixel.y >= size.y) {
        return;
    }

    vec2 uv = (vec2(pixel) + 0.5) / params.resolution;

    float raw_depth = texture(depth_sampler, uv).r;
    float linear_depth = linearize_depth(raw_depth, uv);
    imageStore(depth_write, pixel, vec4(linear_depth, 0.0, 0.0, 1.0));

    vec4 color = texture(color_sampler, uv);
    imageStore(color_write, pixel, color);
}
""";

func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
		access_resolved_color = true
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
				if shared_buffer != null:
						if shared_buffer.texture_rid.is_valid():
								rd.free_rid(shared_buffer.texture_rid)
								shared_buffer.texture_rid = RID()
						if shared_buffer.color_texture_rid.is_valid():
								rd.free_rid(shared_buffer.color_texture_rid)
								shared_buffer.color_texture_rid = RID()

func _build_pipeline() -> void:
		if shader.is_valid():
				rd.free_rid(shader)
				shader = RID()
		if pipeline.is_valid():
				rd.free_rid(pipeline)
				pipeline = RID()

		var src := RDShaderSource.new()
		src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		src.source_compute = COMPUTE_SRC
		var spirv := rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
				push_error(spirv.compile_error_compute)
				return

		shader = rd.shader_create_from_spirv(spirv)
		pipeline = rd.compute_pipeline_create(shader)

		if not sampler.is_valid():
				var sampler_state := RDSamplerState.new()
				sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
				sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
				sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
				sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
				sampler = rd.sampler_create(sampler_state)

func _ensure_output(size: Vector2i) -> bool:
		var needs_rebuild := shared_buffer.size != size \
				or not shared_buffer.texture_rid.is_valid() \
				or not shared_buffer.color_texture_rid.is_valid()
		if not needs_rebuild:
				return true

		if shared_buffer.texture_rid.is_valid():
				rd.free_rid(shared_buffer.texture_rid)
				shared_buffer.texture_rid = RID()
		if shared_buffer.color_texture_rid.is_valid():
				rd.free_rid(shared_buffer.color_texture_rid)
				shared_buffer.color_texture_rid = RID()

		shared_buffer.size = size

		var depth_format := RDTextureFormat.new()
		depth_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		depth_format.width = max(size.x, 1)
		depth_format.height = max(size.y, 1)
		depth_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		depth_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		shared_buffer.texture_rid = rd.texture_create(depth_format, RDTextureView.new(), [])

		var color_format := RDTextureFormat.new()
		color_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		color_format.width = max(size.x, 1)
		color_format.height = max(size.y, 1)
		color_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		color_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		shared_buffer.color_texture_rid = rd.texture_create(color_format, RDTextureView.new(), [])

		return shared_buffer.texture_rid.is_valid() and shared_buffer.color_texture_rid.is_valid()


func _render_callback(p_type: int, p_render_data: RenderData) -> void:
		if not shader.is_valid() or not pipeline.is_valid():
			_build_pipeline()
			if not shader.is_valid() or not pipeline.is_valid():
					return

		if p_type != effect_callback_type:
				return
		if not shader.is_valid() or not pipeline.is_valid():
				return

		var rsb: RenderSceneBuffers = p_render_data.get_render_scene_buffers()
		if rsb == null:
				return

		var size: Vector2i = rsb.get_internal_size()
		if size.x <= 0 or size.y <= 0:
				return
		if not _ensure_output(size):
				return

		var scene_data := p_render_data.get_render_scene_data()

		var projection := scene_data.get_cam_projection()
		var inv_projection := projection.inverse()

		var push := PackedFloat32Array()
		push.append(float(size.x))
		push.append(float(size.y))
		push.append(0.0)
		push.append(0.0)
		for row in range(4):
				for col in range(4):
						push.append(inv_projection[row][col])

		var groups_x := int((size.x - 1) / 8) + 1
		var groups_y := int((size.y - 1) / 8) + 1
		var view_count: int = rsb.get_view_count()

		for view in range(view_count):
				var depth_layer: RID = rsb.get_depth_layer(view)
				if not depth_layer.is_valid() or not shared_buffer.texture_rid.is_valid():
						continue

				var color_layer: RID = rsb.get_color_layer(view)
				if not color_layer.is_valid():
						continue
				if not shared_buffer.color_texture_rid.is_valid():
						continue

				var depth_uniform := RDUniform.new()
				depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				depth_uniform.binding = 0
				depth_uniform.add_id(sampler)
				depth_uniform.add_id(depth_layer)

				var depth_write_uniform := RDUniform.new()
				depth_write_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				depth_write_uniform.binding = 1
				depth_write_uniform.add_id(shared_buffer.texture_rid)

				var color_sampler_uniform := RDUniform.new()
				color_sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				color_sampler_uniform.binding = 2
				color_sampler_uniform.add_id(sampler)
				color_sampler_uniform.add_id(color_layer)

				var color_write_uniform := RDUniform.new()
				color_write_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				color_write_uniform.binding = 3
				color_write_uniform.add_id(shared_buffer.color_texture_rid)

				var uniform_set := UniformSetCacheRD.get_cache(
						shader, 0,
						[depth_uniform, depth_write_uniform, color_sampler_uniform, color_write_uniform]
				)

				var cl := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(cl, pipeline)
				rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
				rd.compute_list_set_push_constant(cl, push.to_byte_array(), push.size() * 4)
				rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
				rd.compute_list_end()
