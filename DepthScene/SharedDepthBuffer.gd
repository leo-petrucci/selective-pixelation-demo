@tool
extends Resource
class_name SharedDepthBuffer

var texture_rid: RID
var color_texture_rid: RID
var size: Vector2i = Vector2i.ZERO
var inv_projection: Transform3D = Transform3D.IDENTITY
