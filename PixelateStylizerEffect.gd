@tool
extends CompositorEffect
class_name PixelateStylizerEffect

## Pixel art stylizer effect that adds shadows and highlights based on depth and normals
## Runs on PRE_TRANSPARENT pass

# Shadow settings
@export var shadows_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var shadow_strength: float = 0.4
@export var shadow_color: Color = Color.BLACK

# Highlight settings
@export var highlights_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var highlight_strength: float = 0.1
@export var highlight_color: Color = Color.WHITE

# Edge/line thickness (in pixels). Values > 1 sample neighbors farther to thicken edges.
@export_range(1.0, 8.0, 0.1) var edge_thickness: float = 1.5

var rd: RenderingDevice
var shader: RID
var pipeline: RID

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	needs_motion_vectors = false
	needs_normal_roughness = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
		if pipeline.is_valid():
			rd.free_rid(pipeline)

func _create_shader() -> void:
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 1, binding = 0) uniform sampler2D depth_texture;
layout(set = 1, binding = 1) uniform sampler2D normal_roughness_texture;

layout(push_constant, std430) uniform Params {
	vec2 screen_size;
	vec2 _pad0;
	mat4 inv_projection;
	float shadows_enabled;
	float highlights_enabled;
	float shadow_strength;
	float highlight_strength;
	vec4 highlight_color; // .a packs edge thickness
	vec4 shadow_color;
} params;

float getDepth(vec2 screen_uv, sampler2D depth_texture, mat4 inv_projection_matrix) {
	float raw_depth = texture(depth_texture, screen_uv).r;
	vec3 normalized_device_coordinates = vec3(screen_uv * 2.0 - 1.0, raw_depth);
	vec4 view_space = inv_projection_matrix * vec4(normalized_device_coordinates, 1.0);
	view_space.xyz /= view_space.w;
	return -view_space.z;
}

float normalIndicator(vec3 normalEdgeBias, vec3 baseNormal, vec3 newNormal, float depth_diff) {
	float normalDiff = dot(baseNormal - newNormal, normalEdgeBias);
	float normalIndicator = clamp(smoothstep(-0.01, 0.01, normalDiff), 0.0, 1.0);
	float depthIndicator = clamp(sign(depth_diff * 0.25 + 0.0025), 0.0, 1.0);
	return (1.0 - dot(baseNormal, newNormal)) * depthIndicator * normalIndicator;
}

void main() {
	ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
	vec2 screen_uv = (vec2(pixel_coords) + 0.5) / params.screen_size;
	vec2 base_e = vec2(1.0) / params.screen_size;
	int r = int(ceil(max(1.0, params.highlight_color.a)));
	
	// Shadows calculation
	float depth_diff = 0.0;
	float neg_depth_diff = 0.5;
	
	if (params.shadows_enabled > 0.5) {
		float depth = getDepth(screen_uv, depth_texture, params.inv_projection);
		for (int i = 1; i <= r; i++) {
			vec2 o = base_e * float(i);
			float du = getDepth(screen_uv + vec2(0.0, -1.0) * o, depth_texture, params.inv_projection);
			float dr = getDepth(screen_uv + vec2(1.0, 0.0) * o, depth_texture, params.inv_projection);
			float dd = getDepth(screen_uv + vec2(0.0, 1.0) * o, depth_texture, params.inv_projection);
			float dl = getDepth(screen_uv + vec2(-1.0, 0.0) * o, depth_texture, params.inv_projection);
			
			depth_diff += clamp(du - depth, 0.0, 1.0);
			depth_diff += clamp(dd - depth, 0.0, 1.0);
			depth_diff += clamp(dr - depth, 0.0, 1.0);
			depth_diff += clamp(dl - depth, 0.0, 1.0);
			
			neg_depth_diff += depth - du;
			neg_depth_diff += depth - dd;
			neg_depth_diff += depth - dr;
			neg_depth_diff += depth - dl;
		}
		neg_depth_diff = clamp(neg_depth_diff, 0.0, 1.0);
		neg_depth_diff = clamp(smoothstep(0.5, 0.5, neg_depth_diff) * 10.0, 0.0, 1.0);
		depth_diff = smoothstep(0.2, 0.3, depth_diff);
	}
	
	// Highlights calculation
	float normal_diff = 0.0;
	
	if (params.highlights_enabled > 0.5) {
		vec3 normal = texture(normal_roughness_texture, screen_uv).rgb * 2.0 - 1.0;
		vec3 normal_edge_bias = vec3(1.0, 1.0, 1.0);
		for (int i = 1; i <= r; i++) {
			vec2 o = base_e * float(i);
			vec3 nu = texture(normal_roughness_texture, screen_uv + vec2(0.0, -1.0) * o).rgb * 2.0 - 1.0;
			vec3 nr = texture(normal_roughness_texture, screen_uv + vec2(1.0, 0.0) * o).rgb * 2.0 - 1.0;
			vec3 nd = texture(normal_roughness_texture, screen_uv + vec2(0.0, 1.0) * o).rgb * 2.0 - 1.0;
			vec3 nl = texture(normal_roughness_texture, screen_uv + vec2(-1.0, 0.0) * o).rgb * 2.0 - 1.0;
			
			normal_diff += normalIndicator(normal_edge_bias, normal, nu, depth_diff);
			normal_diff += normalIndicator(normal_edge_bias, normal, nr, depth_diff);
			normal_diff += normalIndicator(normal_edge_bias, normal, nd, depth_diff);
			normal_diff += normalIndicator(normal_edge_bias, normal, nl, depth_diff);
		}
		normal_diff = smoothstep(0.2, 0.8, normal_diff);
		normal_diff = clamp(normal_diff - neg_depth_diff, 0.0, 1.0);
	}
	
	// Apply effect
	vec3 original_color = imageLoad(color_image, pixel_coords).rgb;
	vec3 final_highlight_color = mix(original_color, params.highlight_color.rgb, params.highlight_strength);
	vec3 final_shadow_color = mix(original_color, params.shadow_color.rgb, params.shadow_strength);
	vec3 final_color = original_color;
	
	if (params.highlights_enabled > 0.5) {
		final_color = mix(final_color, final_highlight_color, normal_diff);
	}
	if (params.shadows_enabled > 0.5) {
		final_color = mix(final_color, final_shadow_color, depth_diff);
	}
	
	imageStore(color_image, pixel_coords, vec4(final_color, 1.0));
}
"""
	
	shader = rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(shader_source))
	pipeline = rd.compute_pipeline_create(shader)

func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if rd and p_effect_callback_type == EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		if not shader.is_valid() or not pipeline.is_valid():
			_create_shader()
		
		var render_scene_buffers := p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var render_scene_data := p_render_data.get_render_scene_data()
			
			var size: Vector2i = render_scene_buffers.get_internal_size()
			if size.x == 0 or size.y == 0:
				return
			
			var view_count: int = render_scene_buffers.get_view_count()
			for view in view_count:
				# Get textures
				var color_image: RID = render_scene_buffers.get_color_layer(view)
				var depth_texture: RID = render_scene_buffers.get_depth_layer(view)
				var normal_texture: RID = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")
				
				if not color_image.is_valid() or not depth_texture.is_valid() or not normal_texture.is_valid():
					continue
				
				# Get projection matrix
				var projection := render_scene_data.get_cam_projection()
				var inv_projection := projection.inverse()
				
				# Prepare push constant data
				var push_constant := PackedFloat32Array()
				push_constant.append(size.x)
				push_constant.append(size.y)
				push_constant.append(0.0) # padding
				push_constant.append(0.0) # padding
				
				# Add inverse projection matrix (16 floats)
				for i in range(4):
					for j in range(4):
						push_constant.append(inv_projection[i][j])
				
				# Add boolean flags (as floats, since GLSL bools in push constants can be tricky)
				push_constant.append(1.0 if shadows_enabled else 0.0)
				push_constant.append(1.0 if highlights_enabled else 0.0)
				
				# Add other parameters
				push_constant.append(shadow_strength)
				push_constant.append(highlight_strength)
				
				# Add colors (as vec4) — pack edge_thickness in highlight alpha
				push_constant.append(highlight_color.r)
				push_constant.append(highlight_color.g)
				push_constant.append(highlight_color.b)
				push_constant.append(edge_thickness)
				push_constant.append(shadow_color.r)
				push_constant.append(shadow_color.g)
				push_constant.append(shadow_color.b)
				push_constant.append(1.0) # alpha padding
				
				# Create uniform sets
				var sampler_state := RDSamplerState.new()
				sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
				sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
				var sampler := rd.sampler_create(sampler_state)
				
				var u0 := RDUniform.new()
				u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u0.binding = 0
				u0.add_id(color_image)
				
				var uniform_set_0 := UniformSetCacheRD.get_cache(shader, 0, [u0])
				
				var u1 := RDUniform.new()
				u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u1.binding = 0
				u1.add_id(sampler)
				u1.add_id(depth_texture)
				
				var u2 := RDUniform.new()
				u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u2.binding = 1
				u2.add_id(sampler)
				u2.add_id(normal_texture)
				
				var uniform_set_1 := UniformSetCacheRD.get_cache(shader, 1, [u1, u2])
				
				# Run compute shader
				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
				rd.compute_list_bind_uniform_set(compute_list, uniform_set_0, 0)
				rd.compute_list_bind_uniform_set(compute_list, uniform_set_1, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				
				var x_groups: int = (size.x + 7) / 8
				var y_groups: int = (size.y + 7) / 8
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()
				
				rd.free_rid(sampler)
